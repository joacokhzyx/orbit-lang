# Windows: what is known, what is open, and how to reproduce it

Both Windows gate failures are **diagnosed and fixed**. Neither was a Windows
defect. What follows is what was measured and what was ruled out, because the
ruled-out lists are the part worth keeping: they are what stops the next person
re-deriving them.

- `tests/suite/object_literals.orb` did not build on the Windows leg — fixed in
  `17bd1b4`.
- The Kynx live gate completed 34 of 200 requests — fixed in `56f4f8d`.

Both were surfaced on 2026-10-09 by splitting CI into five independent jobs.
Before that they were invisible: `Runtime C tests` sat sixth of twenty-four
steps, a failing `run:` skips every step after it, so the fourteen gates below
it had not run on Windows at all. That was the shape of the problem and it is
fixed; these two were what was underneath it.

**Neither was a platform defect.** Both reproduced on a Windows development
machine, and both were fixed without touching anything Windows-specific. Read
that as the lesson rather than as trivia: the leg that fails is the leg whose
toolchain or whose harness differs, and "Windows" was the label for "not
ubuntu/gcc".

---

## 1. `object_literals` did not build — a missing cast arm

The suite was 57/58 on windows-latest against 58/58 on ubuntu. The emitted C
carried one wrong cast:

```c
orbit_object_set_object((OrbitObject*)(r_0), (const char*)("deep"), (const char*)(r_1));
```

against a parameter declared `OrbitObject*` (`runtime/json.c:163`). `c_backend.orb`'s
cast chain for the `orbit_object_set_*` family had an arm each for `float`,
`int` and `bool`, then fell through to `(const char*)`. `set_object` had no
arm.

**The emitted C was byte-identical on every platform.** What differed was the C
compiler's default severity for one diagnostic. gcc 16 rejects it — measured.
The matrix in `ci-gate.yml` runs gcc on ubuntu and clang on windows, so the leg
that fails is whichever toolchain promotes the warning.

The program was *correct* regardless: `orbit_value_object` re-wraps the word
inside the callee, so the wrong cast is behaviourally inert and the program
exits 0 wherever the toolchain tolerates it. That is the whole reason this read
as a platform defect rather than a codegen one.

### Ruled out, and worth keeping

- **Not `buildObjectLiteralAsModel`.** It only runs when the declared type is a
  declared model; `-> object` is not one, so `isModelDeclName` is false and the
  dynamic `buildObjectLiteral` runs instead. It was the handoff's first suspect
  and it is not on this path.
- **Not `orbit_db_*`.** Both are `static` inside a `database.c` this program
  never includes.
- **Not generated C in general.** Parity is 32/32 and `-Werror` was 10/10,
  because not one of those probes contains an object literal — which is how the
  suite went red while the gate built to catch exactly this class stayed green.

### Why it stayed hidden

Only one construct in the corpus reaches the object setter at all: a literal
whose field value is itself a literal. That occurs exactly once, at
`tests/suite/object_literals.orb:43`. A single missing arm, reachable from one
line of one test, presented as an entire platform being broken.

`werror_gate.py` now has a nested-object-literal probe (`object_literal_nested`).
It was run against the unfixed compiler first and fails there, because a new
check that cannot fail is not a check.

---

## 2. The Kynx live gate under-completed — a pipe nobody read

```
Phase A failed: completed=34 error_rate=0.83 status={'200': 34}
```

`kynx_live_gate.py` started the gate server with `stdout=subprocess.PIPE` and
then never read it. On Windows that pipe holds **4352 bytes**; on Linux,
65536. The service writes **118 bytes per request**. So the pipe filled at
request ~38, the server blocked in `write()`, and it never served again. Linux
would have needed ~554 requests to fill the pipe and Phase A only asks 200.

Every later request timed out: 161 × 5s ÷ 2 connections = 409s, against the
419.72s in the log.

### Every number in the failing log was honest and none meant what it appeared to

- `p50=0.213ms` said the server was fast. It was — for the 34 requests it still
  answered. Latency percentiles are computed over the successes only.
- `status={'200': 34}` said nothing was denied. Correct — nothing was. The
  server had accepted every connection and stopped answering. `status_counts`
  is only ever written on the success path, so it is silent about the other 166.
- `error_rate=0.83` was 166 transport failures out of 200 attempts, not 34
  completions inside a window. `failed = transport_errors + (completed - ok_2xx)`,
  and with every status 2xx the second term is zero, so
  `T/(34+T) = 0.83 → T = 166`.

The reading that sent the first attempt wrong was "the runner is slower".
The runner was never the problem.

### Ruled out, and worth keeping

- **Not throughput, pacing, keep-alive reuse or concurrency.** One connection
  at 60 requests: 60/60 in 6.1s. Two connections at the exact Phase A config:
  200/200 in 20.06s. All of it passes when the server's stdout goes to a file.
- **Not a send that silently truncates.** This one was real and is recorded
  because it nearly went the other way: Winsock *does* propagate the listening
  socket's non-blocking mode to accepted sockets (measured) where POSIX
  `accept()` does not, and `orbit_send_response` writes with a single unchecked
  `send()`, which is unsound on a non-blocking socket. Restoring blocking mode
  changed nothing — `completed=38 transport_errors=162 elapsed=409.49s`, the
  same failure. Reverted rather than shipped: a change that claims to fix
  something and does not is worse than the bug, because it closes the report.
- **Not a regression.** The gate had never run on Windows before 2026-10-09.

### What the handoff got wrong, and why it mattered

Three claims in the previous version of this page were not measurements:

1. Phase A was described as wall-clock bounded. With `--requests 200`,
   `night_load.py` sets `stop_at = None` — `--duration` is dead on this path —
   so Phase A is quota-bounded. The suggested remedy, "give Phase A a longer
   window", had no knob to turn.
2. `scripts/kynx_burst_probe.py` was named as the load model. It is not on the
   gate's path at all. `scripts/night_load.py` is.
3. "Phases B and C — the actual burst and the post-burst recovery — pass on
   Windows." They never ran. `b = phase_b(args) if a else False` meant a Phase A
   failure suppressed them. All three phases run now, whatever the others did.

The discriminating numbers (`transport_errors`, `elapsed`) were printed all
along by `night_load.py` and captured by the gate — and dropped by the gate's own
failure line, which is the one place they were needed. The line now carries
them.

---

## What is NOT open

Recorded because these were open once and are green now, and a red herring
costs a whole session.

**The `0xC0000005` in `runtime/test_migrations.c` is fixed.** Root cause:
`runtime/database.c` discarded the return value of `sqlite3_open` and guarded
on the handle with `if (orbit_db_conn)`. SQLite returns a non-NULL handle even
when the open fails, so every statement in `orbit_db_init` ran against a
database that was never opened. The return code is now checked, the handle is
closed and left NULL, and a failure prints the path and SQLite's own message to
stderr. `Runtime C and auth` is green on both platforms.

**The runtime C tests run on Windows**, all twelve, including the one compiled
with `-Wall` and not `-w` because MSVC is the only toolchain here that calls
`strncat` unsafe.

---

## Reproducing

```bash
# everything this repo's own gates do, from a Windows checkout
make check                       # T0..T2
make all                        # adds the root of trust
make report                     # the report-only measurements CI also runs

# the language suite alone
make fp
python3 scripts/test_suite.py --cc gcc --compiler "$(python3 scripts/dev.py fp-path)"
```

`make` is the entry point. `scripts/dev.py` owns `TEMP`/`TMP`,
`ORBIT_CCACHE_DIR`, the fixed-point binary and every gate's flags; you should not
need to pass `--cc` or `--compiler` by hand. On a Windows runner, `make` is
available through Git Bash; CI calls `python3 scripts/dev.py` directly because
the Windows image has no `make`.

There is no `make kynx` target, and there never was — an earlier version of this
page said otherwise, which meant the first command a Windows user ran was
`No rule to make target`. The Kynx live gate is `kynx_live` inside T2; run it on
its own with `python3 scripts/dev.py check --filter kynx_live`.

**Beware `make suite`, `make doctor`, `make parity`, `make werror` and
`make negative`.** They resolve the compiler through `$(shell $(DEV) fp-path)`,
and `fp-path` prints its bootstrap log to stdout when the fixed point is stale.
Make folds the whole log into one argument, so `--compiler` arrives as a
paragraph of text and Python fails with `FileNotFoundError: [WinError 2]`. It
does this exactly when the fixed point needs rebuilding, which is exactly when
you run those targets. `make check` and `make all` are unaffected — they pass
argument lists, not shell substitutions.

**The fixed-point binary lives outside the repository tree, and that is
load-bearing.** The compiler resolves its runtime as `<dir of argv[0]>/runtime`,
so a binary inside the repo makes `doctor_gate`'s `--fix` goldens fail over a
missing `socket_compat.h` AND silently void `cli_probe`'s
`cc-include-failure-is-not-a-missing-toolchain` probe, because that probe
asserts a C include failure that a compiler able to see `runtime/` never
produces. `scripts/dev.py` knows this and puts it in the system temp. If you
build one by hand, build it outside the tree.

---

## Why the coverage was lost in the first place

Worth reading once, because the fix is the reason you can read this page at
all. In GitHub Actions a failing `run:` aborts its step and skips every step
after it. In a single twenty-four-step job that makes the step order the
coverage policy — and one order was chosen by where a block happened to sit in
the file. The workflow is now five independent jobs with no `needs:` between
them, and CI calls `make all && make report`, so the sequence has one executable
form instead of three that had already drifted apart.

The same shape bit the Kynx gate from the inside: a phase that could not run
could not report, and the record written from that run was wrong in three
places. A gate that suppresses its own evidence is the same defect as a job that
skips its steps.

Recorded as **DX-1** in `ENGINEERING.md` §7, along with the measured cost:
the `gates` job is 5 minutes on ubuntu and about 14 on windows-latest.
