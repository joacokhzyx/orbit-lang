# Command Reference

This page separates commands you'll use every day from commands I use to develop and verify the compiler.

## User Commands

These commands operate on an installed Orbit executable or on a locally built executable.

| Command | Purpose | Example |
|---|---|---|
| `orbit build <file>` | Compile an Orbit source file to an executable | `orbit build main.orb -o main` |
| `orbit run <file>` | Build and run it with inherited stdio (servers keep the terminal) | `orbit run main.orb` |
| `orbit start [file]` | Build into `.orbit/` and run it; service mode when it declares routes, program mode otherwise | `orbit start` (= `main.orb`), `orbit start svc.orb --port 8080` |
| `orbit dev [file]` | Watch sources, rebuild and restart on change (drain on POSIX, [kill on Windows](KNOWN_LIMITATIONS.md#windows-drain-is-kill)) | `orbit dev svc.orb` |
| `orbit stop` | Stop the service recorded in `.orbit/start.pid` (idempotent) | `orbit stop` |
| `orbit check <file>` | Parse and typecheck without emitting code | `orbit check main.orb` |
| `orbit fmt <file>` | Format a file (writes only on success) | `orbit fmt main.orb` |
| `orbit fmt --check <file\|dir>` | List files that need formatting | `orbit fmt --check ./compiler` |
| `orbit doctor [dir]` | Project checks; read-only unless `--fix` | `orbit doctor ./examples` |
| `orbit frontend <file>` | Emit the typed IR (TIR) without building | `orbit frontend main.orb` |
| `orbit lextrace <file>` | Developer lexer trace; output is unstable by design | `orbit lextrace main.orb` |
| `orbit cluster ...` | Single-host multiprocess orchestration (up, status, drain, restart, down, logs; see CLUSTER.md) | `orbit cluster up --nodes 3 --port-base 8100` |
| `orbit --help` | Display the command-line help | `orbit --help` |
| `orbit --version` | Display the compiler version | `orbit --version` |
| `orbit` (no arguments) | Short help with next steps | `orbit` |

## Appearance: palette, color and progress

One palette everywhere: red for errors, yellow for warnings and tips,
green for success, cyan for codes and paths, bold for locations, dim for
secondary text. The compiler owns it in `compiler/tools/palette.orb`, the repo
scripts mirror it in `scripts/orbit_output.py`, and the generated server
banner uses the same roles.

Color fires only on a live terminal. Piped and redirected output stays
plain (byte-identical), as do CI logs. `NO_COLOR` set or `TERM=dumb`
always win; `--color always` forces styled output anywhere (for docs and
snapshots) and `--color never` forces plain text. The one gradient lives
on the word `Kynx` in the generated server banner; diagnostics, findings,
help and summaries never use gradients (they must stay greppable).

Progress: `orbit build` prints `Building <in> -> <out>` first and
`wrote <out> in <N> ms` last (both suppressed by `--quiet`). `orbit
doctor` closes text runs with a score box (`N / 100` with a 40-cell bar
plus `N issues across M/F files in Ts`); the box prints on live
terminals, so golden files stay plain. Bare `orbit` prints short help to
stdout and exits 0.

`build`, `run` and `check` accept `--quiet` (less success chatter; errors
always print), `--verbose` (echoes the C compiler invocation on build
and run, the input size on check) and `--color always|never|auto` (styled
output; `auto` paints only on a live terminal and stays plain in pipes).
`build` additionally accepts `--release`, which compiles the emitted unit
at `-O2` instead of the default `-O1` (see [Performance](PERF.md#user-build-optimisation-level)).
`fmt` accepts `--quiet` (single-file
mode) and `--verbose` (scan totals with `--check`). `doctor` accepts
`--fix` (whitespace only: trailing whitespace and a missing final
newline), `--quiet`, `--verbose` (scan scope), `--format json` (findings
as a JSON array of `{file, line, code, severity, message, fix}` on
stdout; exit codes unchanged) and `--color always|never|auto`.
`cluster up/down/drain/restart` accept `--quiet` (errors
only); `up` and `restart` echo spawned commands with `--verbose`. The
child program owns the terminal under `run`, so its output is never
silenced.

On Windows, every binary the compiler links carries Orbit's own metadata:
a version resource (CompanyName `orbit-lang`, ProductName `Orbit`,
FileDescription `Orbit program` / `Orbit service` / `Orbit compiler`,
the compiler version throughout) plus the Orbit mark as its icon whenever
`orbit.ico` sits beside the compiler (installed layout) or in `assets/`
(dev checkout). There is deliberately no syntax for this: the branding is
fixed so a `.orb` file cannot fake it. It needs `windres` or `llvm-rc` on
PATH; without either the build succeeds unstamped with a note on stderr.
Other platforms skip it silently.

`orbit start` builds to `.orbit/<name>[.exe]` (plus `.orbit/data/` for
the database and `.orbit/logs/` for dev output) and runs it, so the
binary never lands next to your source. With no file argument it uses
`main.orb`. `--port N` overrides the service port; with no `--port` the
file's `port` declaration is used, and with neither, the default is 3000.

`Declares routes` means the entry file holds at least one top-level `route METHOD "path"` block, so the build generates a `main` that serves HTTP (service mode) instead of running the `main` you wrote (program mode); see [HTTP routes](SYNTAX_GUIDE.md#http-routes).

`orbit dev` does the same in a watch loop: content-hash poll every
second over the entry file plus its transitive imports, rebuild on
change, graceful stop first (SIGTERM drain on POSIX; kill on Windows,
per [Known Limitations](KNOWN_LIMITATIONS.md#windows-drain-is-kill))
escalating to kill after ~3 s. A failed rebuild
keeps watching without a child; the child pid lives in
`.orbit/dev.pid` so the next `dev` reaps a stale child from Ctrl-C.

Stop a server with Ctrl-C or `orbit stop`: a service binary writes its pid
to `.orbit/start.pid` at boot (only when `.orbit/` exists) and removes it
on graceful shutdown, so `stop` in the project directory ends exactly that
process — SIGTERM drain first on POSIX, kill on Windows per
[Known Limitations](KNOWN_LIMITATIONS.md#windows-drain-is-kill) — escalating
to kill after ~3 s. `stop` is idempotent: nothing recorded, or a stale
record from a killed server, both exit 0 after cleanup. `start` refuses to
build while the recorded server is alive (`already running ... run `orbit stop`
first`) instead of failing the C step on the locked exe. When the terminal
dies first, the next `orbit dev` reaps the stale child through `.orbit/dev.pid`.
A busy port fails quietly on Windows, so confirm the listener (`netstat -ano | findstr <port>`; POSIX: `ss -ltnp | grep <port>`) and pick a free one - see [the port is taken](tutorials/troubleshooting.md#the-port-is-taken---or-is-it). Service output lands under `.orbit/logs/` - tail it (`tail -f .orbit/logs/` on POSIX; `Get-Content -Wait .orbit/logs/` on Windows).

`orbit dev` (watch/reload) is implemented: see above. Calling an
unknown command treats it as a filename and fails - that error message
is honest, not a silent stub.

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
  `file:line severity [D00X] message fix: action`.
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
5. `fmt --check` is clean on `compiler`, `tests/suite`, `std`, `tests/std` and `examples`, `doctor` reports nothing on `tests/suite`, and `cli_probe.py` passes.
6. Documentation and examples reflect the supported behavior.

See [Platform Support](SUPPORT.md), [Getting Started](GETTING_STARTED.md), and the [Engineering Contract](../ENGINEERING.md) for platform-specific details and invariants.
