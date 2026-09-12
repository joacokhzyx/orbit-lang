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
| `orbit cluster ...` | Single-host multiprocess orchestration (up, status, drain, restart, down, logs; see CLUSTER.md) | `orbit cluster up --nodes 3 --port-base 8100` |
| `orbit --help` | Display the command-line help | `orbit --help` |
| `orbit --version` | Display the compiler version | `orbit --version` |

`orbit dev` (watch/reload) is not implemented yet. Calling it treats `dev` as a filename and fails — that error message is honest, not a silent stub.

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
  failed spawns) print `orbit <cmd>: fact. Fix.` to stderr.
- Usage errors print `Usage: ...` and exit 2.

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
5. Documentation and examples reflect the supported behavior.

See [Platform Support](SUPPORT.md), [Getting Started](GETTING_STARTED.md), and the [Engineering Contract](../ENGINEERING.md) for platform-specific details and invariants.
