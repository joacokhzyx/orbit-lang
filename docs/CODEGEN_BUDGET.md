# Codegen budget

What the generated C costs to emit and to build, what was measured, what was
changed, and what was left alone. Same rules as [docs/PERF.md](PERF.md): every
number ships with the command that produced it, the machine it ran on, and the
spread across runs. Comparisons that hide the runs that went badly are
advertising, not engineering.

The brief was narrow on purpose: make **builds faster** and **generated code
smaller**, by restructuring codegen only, with each change measured and
reversible. Two axes, and they turned out to point in different directions —
the one change that landed wins on emitted size and does nothing measurable for
build time, because build time is not spent on the generated code at all. That
is the honest headline of this document.

## Machine and instruments

All measurements below on one box:

- CPU: AMD Ryzen 5 2400G, 4 cores / 8 threads
- RAM: 7.9 GB
- OS: Windows 10 Pro, build 19045
- `gcc` 16.2.0, `python` 3.14.8

The compiler is the fixed-point binary the tree builds (`make fp`, version
`orbit 0.1.0-rc.2`). Two instruments, both runnable from a clean checkout:

**Emitted size.** Run the compiler with the C compiler suppressed and a private
temp dir per program, then read the file it wrote:

```
ORBIT_SKIP_CC=1 ORBIT_WARNINGS=0 TEMP=<private-dir> \
  <fp> build <program.orb> -o <private-dir>/out.exe
# then: bytes/lines of <private-dir>/orbit_selfhost_build.c
```

`ORBIT_SKIP_CC=1` makes the compiler write the intermediate C and stop, so the
number is the *compiler's* output and not the C compiler's. A private `TEMP`
per program keeps concurrent runs from racing on one file.

**Build wall time.** `Measure-Command { <compiler> build <program.orb> -o
out.exe }`, and separately `Measure-Command { gcc -s -O1 <unit> -o out.exe
-Iruntime -DORBIT_WITH_NET -lws2_32 }` on a captured unit.

## Where a plain program's build time goes

`examples/hello.orb` is the floor: 74 lines of emitted C and no routes. Its
full build, 5 runs: **2.955 / 2.999 / 3.041 / 3.121 / 3.379 s**. Orbit's own
phases, with `ORBIT_SKIP_CC=1`, 5 runs: **9.5 / 10.4 / 11.0 / 12.6 / 52.7 ms**.
So the compiler's front end, codegen and IR passes are ~0.3% of the build; the
`cc` child is the rest.

What the `cc` child compiles is not the program. The runtime is source-included
into every translation unit: `runtime.h` pulls in `types.c`, `arena.c`,
`collections.c`, `json.c`, `file.c`, `os.c`, `builtins.c`, `crypto.c`,
`selfhost.c`, `energy.c`, `ledger.c`, `database.c`, `auth.c`, and — under
`-DORBIT_WITH_NET` — `http.c` and `kynx.c`. `gcc -s -O1`, 5 runs each, on this
box:

| translation unit | wall time |
|---|---|
| `int main(void){return 0;}` (empty) | 0.112 / 0.113 / 0.113 / 0.116 / 0.121 s |
| `#include "runtime.h"` with `-DORBIT_WITH_NET` | 2.842 / 2.864 / 2.869 / 2.911 / 2.913 s |
| the compiler's own emitted unit (5,681,069 B) | 16.2 / 16.6 / 21.7 s (3 runs) |

The runtime include tree is ~2.87 s of the ~3.0 s build. A user program's own
text — 1.8 KB for `hello.orb` — is rounding error next to it. **This is why no
codegen change in this document moves build wall time, and why the two changes
that would have moved it are recorded below as negatives.**

## Emitted size: the baseline

Before any change in this document (`adb8b96`), summing the emitted `.c` of
every program in the tree, one compiler run each, `ORBIT_SKIP_CC=1`:

| group | programs | emitted C (bytes) |
|---|---|---|
| `tests/suite/` | 72 | 1,718,257 |
| `tests/std/` | 23 | 1,369,587 |
| `examples/` | 14 | 532,801 |
| `compiler/host/main.orb` | 1 | 5,689,988 |

Two facts shaped every candidate:

1. **A trivial program is almost all prelude.** `examples/hello.orb` emitted
   **10,838 bytes** for a program whose own body is two `print` calls. The rest
   is a fixed block the emitter writes for every program regardless of what the
   program is.
2. **A large program is almost all program.** The compiler's own unit is
   **5,689,988 bytes / 156,181 lines**. By line, register assignment is **48.6%
   of bytes** (54,072 lines / 2,761,364 B of 5,681,069) and register
   declaration is **17.8%** (39,844 lines / 1,012,027 B) — a flat register
   machine, one line per move.

So the prelude dominates small programs and program text dominates the big one;
a change only moves the axis it is aimed at.

## What was changed

### The router block is not emitted for programs that have no routes

The emitted C carries an HTTP entry point (`orbit_handle_request`) and the
request-logging and Kynx-admission helpers it uses. They are reached only from
the worker loop that a program *with routes* emits. A program with no routes has
no caller for any of it and links without it: the unit defines
`ORBIT_CUSTOM_ROUTER`, so `runtime/http.c`'s fallback definition stays disabled,
and nothing references the missing symbols. It was emitted for every program
anyway, wrapped in `#ifdef ORBIT_WITH_NET` (which is always defined), so every
program parsed 201 lines of C it could never reach.

`generateC` (`compiler/emit/c_backend.orb`) now emits the block only when
`moduleHasRoute(backend)` is true — one condition around the existing
`generateRouterBlock(backend)` call, no new code.

Emitted-C bytes, fixed-point compiler, `ORBIT_SKIP_CC=1 ORBIT_WARNINGS=0`,
private TEMP per program:

| group | before | after | delta |
|---|---|---|---|
| `examples/hello.orb` | 10,838 | 1,762 | **−9,076 (−83.7%)** |
| `tests/suite/` (72) | 1,718,257 | 1,064,785 | −653,472 (−38.0%) |
| `tests/std/` (23) | 1,369,587 | 1,160,839 | −208,748 (−15.2%) |
| `examples/` (14) | 532,801 | 487,421 | −45,380 (−8.5%) |
| `compiler/host/main.orb` | 5,689,988 | 5,681,069 | −8,919 (−0.16%) |

Every changed program drops *exactly* 9,076 bytes (8,919 for the compiler unit,
whose prelude differs). **Route programs are byte-identical**: 9 of the 14
examples and every `tests/parity` route case are unchanged.

Build wall time: **unchanged within noise.** `gcc -s -O1` on the emitted unit,
5 runs each, before 3.501 / 3.692 / 3.747 / 3.927 / 3.964 s, after 3.869 /
4.103 / 4.301 / 5.483 / 5.746 s — the spread is larger than the effect, which
is what the section above predicts: removing 201 lines from a unit that spends
2.87 s in `runtime.h` cannot show. The win is generated-code size, not build
time.

**Falsifier, run before landing.** Stripping the block by hand from `hello.c`
(lines 45–245) leaves a file that compiles, links and runs with the same
output. Separately: no file in `runtime/` reads `ORBIT_LOGS_ACTIVE` or
`ORBIT_KYNX_ACTIVE`, so the block's two `#define`s are not load-bearing
anywhere else — they only gate the block itself.

**Cost.** The canonical had to be re-promoted (`make promote`): every `.orb`
edit does. `compiler/selfhost/stage3.exe.c`
`fbd94eb6b32bbd5d4c1aa33c8491edb5cc5bde9c947f802243ea3e3fc1f2e791` →
`4683af7422012dc18cf911cf6db5f744e820a2af3f00d432cc30b0139dddc5d6`, and
`make promote-diff` reports the change as `+6 −201` lines after register
renumbering, in `generateC` and `orbit_main` only — the guard and its comment
in, the block out. Five parity C-hash goldens refreshed for the non-route cases
(`c1_model`, `c5_keyword_names`, `r14_noroute_enum`, `trivial`, `trivial2`);
every `DIAG` golden and every route golden is unchanged. `make check` 17/17,
`make all` 21/21.

## What was measured and left alone

Each of these was tried or analysed and left alone, with the reasoning kept.
None of them is a bug; they are the negative results that bound the win.

- **Selecting the runtime by program (`-DORBIT_WITH_NET` only for programs that
  need it).** Every unit is compiled with `-DORBIT_WITH_NET`
  (`compiler/host/pipeline.orb`), which pulls `http.c` (55,039 B) and `kynx.c`
  (49,056 B) into every build. Dropping it for a program with no network use
  looks like the obvious build-time lever, and it is not one: `gcc -s -O1 -Wall`
  on `#include "runtime.h"`, 5 runs each, is 2.842 / 2.864 / 2.869 / 2.911 /
  2.913 s *with* the flag and 2.885 / 3.055 / 3.058 / 3.137 / 3.163 s
  *without* it — no faster, inside the noise. Two files out of twenty in an
  include tree is not where the second costs; the win would have to come from a
  smaller tree, which is a different piece of work. Not landed, and it would
  also need a "does this program use the network" analysis the front end does
  not have (unlike `moduleUsesDatabase`, which exists for the database).
- **Register traffic (48.6% of the compiler unit's bytes).** The largest single
  term by line and byte, so it is where the next win would have to come from.
  It is not a dead-code pattern: naming shows the moves are live, and the
  emitter already has `markUsedLocals` for the locals that are not. Reducing it
  means a different register allocation, not a codegen tidy — a semantic change
  to the emitted program, which the brief rules out. Recorded as the top of the
  next budget, not attempted here.
- **Dead emitted functions.** `.orbit`-local scan of the compiler unit: 0
  unreferenced functions among 618 definitions, and the same for the shard
  header's 98 (179,760 B). In small programs the only unreferenced definitions are the
  route entry points, which the change above now removes outright. There is no
  dead-function term left to collect.
- **Items already measured elsewhere, not redone.** `-Wall` costs 5.7x on the
  compiler unit (docs/PERF.md), the builder's temporary-sinking loop and
  `variableDefType` rescan were the quadratic passes and are already O(n)
  (docs/PERF.md), and repeated compilations are already served by
  `scripts/orbit_ccache.py`. Re-measuring them would be redoing work, not
  bounding it.

## Reproducing

```
make fp                       # the compiler all of the above measured
make check                    # T0..T2, 17 gates
make all                      # T0..T3, 21 gates, root of trust included
```

Emitted size, per program, by hand:

```
ORBIT_SKIP_CC=1 ORBIT_WARNINGS=0 TEMP=$(mktemp -d) <fp> build <program.orb>
wc -c "$TEMP/orbit_selfhost_build.c"
```

The per-group totals above were collected by a loop over
`tests/suite/*.orb`, `tests/std/*.orb`, `examples/*.orb` and
`compiler/host/main.orb` running exactly that command with a fresh `TEMP` each
time.
