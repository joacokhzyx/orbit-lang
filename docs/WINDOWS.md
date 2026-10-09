# Windows: what is known, what is open, and how to reproduce it

Two gates fail on `windows-latest` and nowhere else. Both have been that way
long enough that the rest of the Windows gate went dark around them, so this
page exists to hand the work over without re-deriving it.

**Neither has been diagnosed.** What follows is what was measured, what was
ruled out, and where to look first. Nothing here is a guess dressed up as a
finding.

Both were surfaced on 2026-10-09 by splitting CI into five independent jobs.
Before that they were invisible: `Runtime C tests` sat sixth of twenty-four
steps, a failing `run:` skips every step after it, so the fourteen gates below
it -- the doctor gates, the CLI probe, both suites, the negative corpus, the
frontend goldens, -Werror, the unknown ratchet, the Kynx live gate -- had not
run on Windows at all. That is the shape of the problem and it is fixed; these
two are what was underneath it.

---

## 1. `object_literals` does not build

The language suite is **57/58 on windows-latest** against **58/58 on ubuntu**.

```console
$ <orbit> check tests/suite/object_literals.orb
Checked tests/suite/object_literals.orb: no errors.
$ <orbit> build tests/suite/object_literals.orb -o probe
... fails, rc=1
```

`orbit check` accepts it and the build does not produce a binary.

**The runner used to hide the reason and no longer does.**
`scripts/test_suite.py` captured the compiler's `stderr` and then printed its
`stdout`, which for a failed build is empty -- so every build failure in the
suite reported `did not build (rc=1) :: (no output)` and the diagnostic went
nowhere. `orbit build` writes diagnostics to `stderr` (DX-0 in `ENGINEERING.md`
moved them there deliberately). The runner now reads `stderr` first, so the
next Windows run carries gcc's actual message in the log and in the job
summary. **Read that first; it is probably the whole investigation.**

### Ruled out

- Not the toolchain. `Runtime C and auth` compiles and links twelve C programs
  on Windows with clang, including one that uses SQLite.
- Not the schema or the builder reaching a broken state. The other 57 suite
  programs build, including `model_literal_fields.orb`, `model_fields.orb` and
  `model_mutation.orb`, which use the same `ObjectLiteral` path.
- Not the emitted-C path in general. Parity is 32/32 on Windows and `-Werror`
  is 10/10, so generated C compiles clean across `tests/parity` and
  `tests/std`.

### Where to look

`object_literals.orb` uses the dynamic object literal, so the suspects are the
ones that treat `ObjectLiteralNode` differently from a model literal:

- `buildObjectLiteralAsModel` in `compiler/builder.orb`, which
  `buildLastStatementValue` calls when a function's return type is a declared
  model and the returned expression is an object literal. That is the
  `ASTNode.ObjectLiteral(ol)` arm inside `buildLastStatementValue`, and it is
  the one path an object literal takes that a model literal does not.
- `orbit_db_append_json_escaped` and `orbit_db_row_to_json` in
  `runtime/database.c`, if the failure is at link or run rather than compile.

---

## 2. The Kynx live gate under-completes

```
Phase A failed: completed=34 error_rate=0.83 status={'200': 34}
```

`scripts/kynx_route_limit_gate.py` asks for 200 requests to `/health` and 34
completed.

**Every request that completed returned 200.** So this is not a correctness
failure: nothing returned an error, nothing was denied, the burst limiter was
not involved. It is 34 requests completing inside whatever window Phase A has.

### Ruled out

- Not the route limiter. Phases B and C -- the actual burst and the
  post-burst recovery -- pass on Windows.
- Not the service. It starts, `/health` answers, and `blog_api.orb` builds from
  the fixed point on Windows.
- Not a regression. This gate had **never run on Windows before 2026-10-09**,
  because it was step seventeen of twenty-four.

### Where to look

The difference from Linux is the machine, not the code: the local run is 25 s
on a 2-core container and about 8 minutes on a Windows runner. Phase A is
wall-clock bounded, so a slower runner finishes fewer requests and the gate
reports a count against a deadline. Three things worth separating:

1. **Is the accept rate the problem?** Read how many connection attempts the
   server saw versus how many completed. If attempts are ~200 and completions
   ~34, it is throughput. If attempts are ~34, the client gave up early.
2. **Is the deadline the problem?** `scripts/kynx_burst_probe.py` has the load
   model; give Phase A a longer window on Windows and see whether the count
   reaches 200. If it does, the gate is measuring the runner and the fix is a
   platform-aware window, not a code change.
3. **Only then** look for a real defect: socket handling, the per-IP
   admission path, or `orbit_socket_t` behaviour. `runtime/socket_compat.h` is
   where the Windows socket differences live.

---

## What is NOT open

Recorded because these were open once and are green now, and a red herring is
expensive.

**The `0xC0000005` in `runtime/test_migrations.c` is fixed.** Root cause:
`runtime/database.c` discarded the return value of `sqlite3_open` and guarded on
the handle with `if (orbit_db_conn)`. SQLite returns a non-NULL handle even when
it opens fails -- it exists so the caller has something to close, and it is
unusable -- so every statement in `orbit_db_init` ran against a database that
was never opened. The return code is now checked, the handle is closed and left
NULL so the `if (!orbit_db_conn) return false` guards that already guard the
rest of that file actually fire, and a failure prints the path and SQLite's own
message to stderr. `Runtime C and auth` is green on both platforms.

**The runtime C tests run on Windows**, all twelve, including the one compiled
with `-Wall` and not `-w` because MSVC is the only toolchain here that calls
`strncat` unsafe.

---

## Reproducing either one

```bash
# everything this repo's own gates do, from a Windows checkout
make check                       # T0..T2
make all                        # adds the root of trust
make runtime                    # the twelve C programs
make kynx                       # builds a service and bursts it

# the language suite alone
make fp
<orbit> build tests/suite/object_literals.orb -o probe
```

`make` is the entry point. `scripts/dev.py` owns `TEMP`/`TMP`,
`ORBIT_CCACHE_DIR`, the fixed-point binary and every gate's flags; you should not
need to pass `--cc` or `--compiler` by hand. On a Windows runner, `make` is
available through Git Bash; CI calls `python3 scripts/dev.py` directly because
the Windows image has no `make`.

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
coverage policy -- and one order was chosen by where a block happened to sit in
the file. The workflow is now five independent jobs with no `needs:` between
them, and CI calls `make all && make report`, so the sequence has one executable
form instead of three that had already drifted apart.

Recorded as **DX-1** in `ENGINEERING.md` §7, along with the measured cost:
the `gates` job is 5 minutes on ubuntu and about 14 on windows-latest.