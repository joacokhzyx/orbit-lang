# Command Reference

This page separates commands you'll use every day from commands I use to develop and verify the compiler.

## User Commands

These commands operate on an installed Orbit executable or on a locally built executable.

| Command | Purpose | Example |
|---|---|---|
| `orbit build <file>` | Compile an Orbit source file to an executable | `orbit build main.orb -o main` |
| `orbit run <file>` | Build and run it with inherited stdio (servers keep the terminal) | `orbit run main.orb` |
| `orbit check <file>` | Parse and typecheck without emitting code | `orbit check main.orb` |
| `orbit fmt <file>` | Format a file (writes only on success) | `orbit fmt main.orb` |
| `orbit fmt --check <file\|dir>` | List files that need formatting | `orbit fmt --check ./compiler` |
| `orbit doctor [dir]` | Read-only project checks | `orbit doctor ./examples` |

`build`, `run` and `check` accept `--quiet` (less success chatter; errors
always print) and `--verbose` (echoes the C compiler invocation on build
and run, the input size on check). `fmt` accepts `--quiet` (single-file
mode) and `--verbose` (scan totals with `--check`). `doctor` accepts
`--quiet`, `--verbose` (scan scope) and `--format json` (findings as a
JSON array of `{file, line, code, message, fix}` on stdout; exit codes
unchanged). `cluster up/down/drain/restart` accept `--quiet` (errors
only); `up` and `restart` echo spawned commands with `--verbose`. The
child program owns the terminal under `run`, so its output is never
silenced.
| `orbit cluster ...` | Single-host multiprocess orchestration (up, status, drain, restart, down, logs; see CLUSTER.md) | `orbit cluster up --nodes 3 --port-base 8100` |
| `orbit --help` | Display the command-line help | `orbit --help` |
| `orbit --version` | Display the compiler version | `orbit --version` |

`orbit dev` (watch/reload) is not implemented yet. Calling it treats `dev` as a filename and fails - that error message is honest, not a silent stub.

When Orbit was built locally and is not installed on `PATH`, call it by its path:

```powershell
.\orbit.exe build main.orb -o main.exe
.\orbit.exe run main.orb
```

```sh
./orbit build main.orb -o main
./orbit run main.orb
```

The exact options supported by a command are defined by the compiler returned by `orbit --help`.

## Errors and exit codes

One format everywhere: fact, then fix, then an optional tip. Headers stay
plain so a tired dev can act without decoding anything.

- Compiler diagnostics (parse/typecheck/codegen) print an error card to
  stderr:
  `error[code]: message` + `--> file:line:col` + the source line with
  `^-- here` + `= help: hint`.
- `orbit doctor` findings print one line to stdout:
  `file:line [D00X] message fix: action`.
- Operational failures (`orbit fmt`, `orbit cluster`, unreadable files,
  failed spawns) print `orbit <cmd>: fact.` to stderr.
- Usage errors print `Usage: ...` to stderr and exit 2. `--help` prints
  the same text to stdout and exits 0. An unknown top-level command
  prints usage to stderr and exits 2.

Exit codes: `0` clean, `1` clean failure (findings, unreadable file,
compile error, failed health), `2` usage (missing or invalid flags,
unknown subcommand). The fuzzer accepts 0, 1, and 2.

| Command | 0 | 1 | 2 |
|---|---|---|---|
| `build` | emitted | unreadable input, parse/typecheck error, C write/compile failure | missing input file, bad flags |
| `run` | child exit code | unreadable input, compile error | missing input file |
| `check` | no errors | unreadable input, parse/typecheck error | missing input file |
| `fmt` / `fmt --check` | formatted / clean | unreadable/unwritable file, input has errors, files need formatting | missing target, bad flags |
| `doctor` | no findings | findings, no `.orb` files found | bad flags, too many args |
| `cluster` | success (status reads state even with dead nodes) | compile/spawn/health/kill errors, unknown node, unreadable state, survivors after down | missing/invalid flags, unknown subcommand |
| `frontend` | TIR written | unreadable input, diagnostics contain errors, write failed | missing input file |

Colors and the server banner stay plain when `NO_COLOR` is set or
`TERM=dumb`: no ANSI escapes, no gradient, no checkmarks. `/_ledger`
and `/_pulse` HTML pages are not terminal output and are unaffected.

## Script output conventions

The Python gates in `scripts/` share one calm grammar (no `[tag]`
prefixes, no colors, no emojis):

- Steps read as actions: `Checking parity r1_route_only ... match`,
  `Testing arith ... exit 0 as expected`, `Building seed ...`.
- Failures print a fact to stderr, then a next step:
  `Failed arith: got exit 3, want 0` followed by
  `Tip: run ... to see why`.
- Every tool closes the same way on stdout:
  `Finished suite: 21/21 pass`.
- `::error::` annotations print only on GitHub Actions
  (`GITHUB_ACTIONS=true`); local runs stay clean.
- Long tools (`build_selfhost`, `verify_seed`, `parity_selfhost`,
  `test_suite`, `measure_selfhost`) accept `--quiet`: only failures
  and the `Finished` line print.
- Success lines pinned by `cli_probe.py` (`wrote`, `Checked`,
  `Formatted`, `Usage:`, exit codes) never change shape.

`scripts/preview_output.py` prints a visual specimen of the grammar
for review; `scripts/orbit_output.py` implements it.

## Compiler Build and Verification

These commands are for contributors and release maintainers:

| Command | Purpose |
|---|---|
| `python scripts/build_selfhost.py --out <path>` | Build the compiler from the committed canonical C source |
| `python scripts/build_selfhost.py --check-stale` | Confirm the generated fixed point matches the committed canonical source |
| `python scripts/verify_seed.py --cc <compiler>` | Rebuild and verify the C seed and self-host chain |
| `python scripts/verify_seed.py --cc <compiler> --emit-fixed-point <path>` | Emit a compiler binary for local gates |
| `python scripts/parity_selfhost.py --cc <compiler> --compiler <path>` | Compare compiler output with committed parity goldens |
| `python scripts/test_suite.py --cc <compiler> --compiler <path>` | Compile and execute the language behavior suite |
| `python scripts/build_selfhost.py --promote` | Promote an intentional compiler change to the canonical C artifact |

Use the commands from the repository root. Set `ORBIT_CC` or pass `--cc` when the C compiler is not detected automatically.

## Quality Gates

A compiler change is not complete until the relevant gates pass:

1. The self-hosted compiler converges.
2. The canonical C source is current when the change is intentional.
3. The parity probes match their goldens.
4. The behavior suite passes.
5. `fmt --check` is clean on `compiler`, `tests/suite` and `examples` (except the intentionally unparseable `orbit_full_expansion.orb`), `doctor` reports nothing on `tests/suite`, and `cli_probe.py` passes.
6. Documentation and examples reflect the supported behavior.

See [Platform Support](SUPPORT.md), [Getting Started](GETTING_STARTED.md), and the [Engineering Contract](../ENGINEERING.md) for platform-specific details and invariants.
