# Command Reference

This page separates the commands you'll use every day from the commands used to develop and verify the compiler.

## User Commands

These commands operate on an installed Orbit executable or on a locally built executable.

| Command | Purpose | Example |
|---|---|---|
| `orbit build <file>` | Compile an Orbit source file to an executable | `orbit build main.orb -o main` |
| `orbit build --backend=native <file>` | The same, through R6 and without a C compiler (Windows and Linux x86-64) | `orbit build --backend=native main.orb -o main` |
| `orbit run <file>` | Build and run it with inherited stdio (servers keep the terminal) | `orbit run main.orb` |
| `orbit start [file]` | Build into `.orbit/` and run it; service mode when it declares routes, program mode otherwise | `orbit start` (= `main.orb`), `orbit start svc.orb --port 8080` |
| `orbit dev [file]` | Watch sources, rebuild and restart on change (drains on both hosts; [the Windows ask is a named channel](internals/LIMITATIONS_LOG.md#a-windows-stop-drains-through-a-named-channel)) | `orbit dev svc.orb` |
| `orbit stop` | Stop the service recorded in `.orbit/start.pid` (idempotent) | `orbit stop` |
| `orbit migrate <file>` | Apply the program's migrations and exit; `ORBIT_MIGRATE_DOWN=<version>` rolls back to that version | `orbit migrate main.orb` |
| `orbit check <file>` | Parse, typecheck and verify the IR without emitting code | `orbit check main.orb` |
| `orbit fmt <file>` | Format a file (writes only on success) | `orbit fmt main.orb` |
| `orbit fmt --check <file\|dir>` | List files that need formatting | `orbit fmt --check ./compiler` |
| `orbit doctor [dir]` | Project checks; read-only unless `--fix` | `orbit doctor ./examples` |
| `orbit frontend <file>` | Emit the typed IR (TIR) without building; the document goes to stdout unless `-o` names a file | `orbit frontend main.orb` |
| `orbit lextrace <file>` | Developer lexer trace; output is unstable by design | `orbit lextrace main.orb` |
| `orbit cluster ...` | Single-host multiprocess orchestration (up, status, drain, restart, down, logs; see CLUSTER.md) | `orbit cluster up --nodes 3 --port-base 8100` |
| `orbit lsp` | Language server on stdin/stdout: JSON-RPC 2.0 framing and diagnostics from `orbit check` | started by the editor, not by hand |
| `orbit --help` | Display the command-line help | `orbit --help` |
| `orbit --version` | Display the compiler version | `orbit --version` |
| `orbit` (no arguments) | Short help with next steps | `orbit` |

## Language server

`orbit lsp` speaks JSON-RPC 2.0 over stdin and stdout, with `Content-Length`
framing. It answers `initialize` with `textDocumentSync: 1`: every `didChange`
carries the whole document, so the server keeps no incremental state it could
get wrong. `didOpen` and `didChange` publish diagnostics, `shutdown` answers
`null`, and `exit` ends the process. A method the server does not know is
answered with `-32601` only when the message carried an `id`, because a
notification has nowhere to put a response.

Diagnostics come from `orbit check` on a temporary file, so the editor and the
command line cannot disagree about what a program means. The cost is one check
process per change. Editors start the server themselves; for example, Neovim:

```lua
vim.lsp.start({ name = "orbit", cmd = { "orbit", "lsp" }, root_dir = vim.fn.getcwd() })
```

## Appearance: palette, color and progress

One palette everywhere: red for errors, yellow for warnings and tips,
green for success, cyan for codes and paths, bold for locations, dim for
secondary text. The compiler owns it in `compiler/tools/palette.orb`, the repo
scripts mirror it in `scripts/orbit_output.py`, and the generated server
banner uses the same roles.

Color fires only on a live terminal. Piped and redirected output stays
plain (byte-identical), as do CI logs. `NO_COLOR` set or `TERM=dumb`
always win. `--color always` forces styled output anywhere (for docs and
snapshots) and `--color never` forces plain text. The generated server banner has one gradient, on the word `admission`. Findings and
the plain tier never use gradients (they must stay greppable). On a console that
takes UTF-8 and 256 colors the compiler also draws cards, stage bars with a
gradient and animated progress; [Terminal output](#terminal-output) lists the tiers and the
overrides (`ORBIT_UI`, `ORBIT_UI_MOTION`).

Progress: `orbit build` prints `Building <in> -> <out>` first and
`wrote <out> in <N> ms` last (both suppressed by `--quiet`). `orbit
doctor` closes text runs with a score box (`N / 100` with a 40-cell bar
plus `N issues across M/F files in Ts`). The box prints on live
terminals, so golden files stay plain. Bare `orbit` prints short help to
stdout and exits 0.

`build`, `run` and `check` accept `--quiet`, `--verbose` and `--color`.
`--quiet` cuts success chatter. Errors always print. `--verbose` echoes the C
compiler invocation on build and run, and the input size on check.
`--color always|never|auto` styles the output. `auto` paints only on a live
terminal and stays plain in pipes.
`build` additionally accepts `--release`, which compiles the emitted unit
at `-O2` instead of the default `-O1` (see [Performance](internals/PERF.md#user-build-optimisation-level)).
`fmt` accepts `--quiet` (single-file
mode) and `--verbose` (scan totals with `--check`). `doctor` accepts
`--fix` (whitespace only: trailing whitespace and a missing final
newline), `--quiet`, `--verbose` (scan scope), `--format json` (findings
as a JSON array of `{file, line, code, severity, message, fix}` on
stdout, with exit codes unchanged) and `--color always|never|auto`.
`cluster up/down/drain/restart` accept `--quiet` (errors
only). `up` and `restart` echo spawned commands with `--verbose`. The
child program owns the terminal under `run`, so its output is never
silenced.

On Windows, every binary the compiler links carries Orbit's own metadata.
That is a version resource (CompanyName `orbit-lang`, ProductName `Orbit`,
FileDescription `Orbit program` / `Orbit service` / `Orbit compiler`,
the compiler version throughout). It is also the Orbit mark as the icon,
whenever `orbit.ico` sits beside the compiler (installed layout) or in `assets/`
(dev checkout). There is deliberately no syntax for this: the branding is
fixed so a `.orb` file cannot fake it. It needs `windres` or `llvm-rc` on
PATH. Without either the build succeeds unstamped with a note on stderr.
Other platforms skip it silently.

`orbit start` builds to `.orbit/<name>[.exe]` (plus `.orbit/data/` for
the database and `.orbit/logs/` for dev output) and runs it, so the
binary never lands next to your source. With no file argument it uses
`main.orb`. `--port N` overrides the service port. With no `--port` the
file's `port` declaration is used, and with neither, the default is 3000.

`Declares routes` means the entry file holds at least one top-level `route METHOD "path"` block, so the build generates a `main` that serves HTTP (service mode) instead of running the `main` you wrote (program mode). See [HTTP routes](LANGUAGE_REFERENCE.md#http-routes).

`orbit dev` does the same in a watch loop. It polls a content hash every
second over the entry file plus its transitive imports, and rebuilds on
change. It stops the child gracefully first (SIGTERM on POSIX, a named stop
channel on Windows, per [Known Limitations](internals/LIMITATIONS_LOG.md#a-windows-stop-drains-through-a-named-channel)),
escalating to kill after ~3 s. A failed rebuild
keeps watching without a child. The child pid lives in
`.orbit/dev.pid` so the next `dev` reaps a stale child from Ctrl-C.

Stop a server with Ctrl-C or `orbit stop`. A service binary writes its pid
to `.orbit/start.pid` at boot (only when `.orbit/` exists) and removes it
on graceful shutdown. So `stop` in the project directory ends exactly that
process: SIGTERM drain first on POSIX, a named stop channel on Windows per
[Known Limitations](internals/LIMITATIONS_LOG.md#a-windows-stop-drains-through-a-named-channel), escalating
to kill after ~3 s. `stop` is idempotent: nothing recorded, or a stale
record from a killed server, both exit 0 after cleanup. `start` refuses to
build while the recorded server is alive (`already running ... run `orbit stop`
first`) instead of failing the C step on the locked exe. When the terminal
dies first, the next `orbit dev` reaps the stale child through `.orbit/dev.pid`.
A busy port fails quietly on Windows, so confirm the listener (`netstat -ano | findstr <port>`; POSIX: `ss -ltnp | grep <port>`) and pick a free one - see [the port is taken](tutorials/troubleshooting.md#the-port-is-taken---or-is-it). Service output lands under `.orbit/logs/` - tail it (`tail -f .orbit/logs/` on POSIX; `Get-Content -Wait .orbit/logs/` on Windows).

`orbit dev` (watch/reload) is implemented. Calling an
unknown command treats it as a filename and fails with a real error,
not a silent stub.

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

## Backends: C and native

`orbit build` and `orbit run` take `--backend=c|native`. `ORBIT_BACKEND` sets
the same choice for every command that builds, and the flag wins over it.
The default is `native` when the compiler finds an `r6` it can run, and `c` otherwise. An unknown name is a usage error (exit 2) for the flag and
a build error (exit 1) for the variable.

- `c` emits C and runs the system C compiler (`ORBIT_CC`, else `CC`, else `cc`).
- `native` writes the IR document that `--emit-ir` writes (see
  [the IR specification](IR_SPEC.md)) into the temp directory and runs R6, a
  separate x86-64 code generator, on it. No C compiler is involved. R6 builds
  the host's format: a PE on Windows, an ELF on Linux x86-64. An `r6` built
  for another host is refused with its own diagnostic, and there is no
  cross build.

A refusal by R6 is a compile error. R6's own line
(`r6: <file>:<line>:<col>: error[CODE]: <msg>`) is printed as R6 wrote it,
followed by one `orbit build:` line with R6's exit code and the command that
builds the program with the C backend. There is no fallback to C. The programs
R6 refuses today include every program that declares a route
(`error[E_UNSUPPORTED]: admission routes are outside the M1 native subset`), so
`orbit start`, `orbit dev` and `orbit cluster` need `--backend=c`
(`cluster` always uses it).

`ORBIT_SKIP_CC` means "emit the intermediate C and stop". It forces the C
backend whatever was requested, because the bootstrap reads that C. `--emit-ir
<path>` keeps its meaning: with `native` the IR is written to that path and R6
reads it from there.

R6 is found in this order:

| Order | Where | Layout |
|---|---|---|
| 1 | `ORBIT_R6` | The path of `r6`. A path that does not exist is an error, not a fall-through. |
| 2 | `r6` in the directory of `orbit` | A portable directory. |
| 3 | `bin/r6` under the directory of `orbit` | The installed layout. |
| 4 | none found | `orbit build: the native backend needs r6 and couldn't find it`. |

Both directories are tried as `r6` and `r6.exe`, because a Windows install
ships the extension and a Linux build does not.

The installed layout is one root, shown for Windows; Linux names the same two
files `orbit` and `bin/r6`:

```text
<root>\orbit.exe        the compiler, on PATH
<root>\bin\r6.exe       the native backend
<root>\lib\             libruntime_net.a, libruntime_net_db.a, sqlite3.lib
<root>\runtime\  std\  as before
```

The runtime archives that R6 links come from the directory in the environment
variable `R6_RUNTIME_DIR`, which `orbit` sets for the R6 process to
`ORBIT_R6_RUNTIME` when that is set, else to `<root>\lib` when it holds
`libruntime_net.a`. When neither exists the variable is left as the caller has
it. `orbit` also sets `R6_TMPDIR` to the build temp directory.

| Variable | Effect |
|---|---|
| `ORBIT_BACKEND=c\|native` | Backend for every build; the flag wins. |
| `ORBIT_R6` | Path of `r6`. |
| `ORBIT_R6_RUNTIME` | Directory of the runtime archives; becomes `R6_RUNTIME_DIR`. |

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
| `frontend` | TIR printed, to stdout or to the file `-o` names | unreadable input, diagnostics contain errors, write failed | missing input file, `-o` without a path |
| `migrate` | migrations applied | unreadable input, compile error, migration failed, no migrations declared | missing input file, bad flags |

Colors and the server banner stay plain when `NO_COLOR` is set or
`TERM=dumb`: no ANSI escapes, no gradient, no checkmarks. `/_ledger`
and `/_pulse` HTML pages are not terminal output and are unaffected.

## Compiler Build and Verification

These commands are for contributors and release maintainers:

| Command | Purpose |
|---|---|
| `python scripts/trust.py build --out <path>` | Build the compiler from the committed canonical C source |
| `python scripts/trust.py build --check-stale` | Confirm the generated fixed point matches the committed canonical source |
| `python scripts/trust.py verify --cc <compiler>` | Rebuild and verify the C seed and self-host chain |
| `python scripts/trust.py verify --cc <compiler> --emit-fixed-point <path>` | Emit a compiler binary for local gates |
| `python scripts/corpus_gates.py parity --cc <compiler> --compiler <path>` | Compare compiler output with committed parity goldens |
| `python scripts/corpus_gates.py suite --cc <compiler> --compiler <path>` | Compile and execute the language behavior suite |
| `python scripts/trust.py build --promote` | Promote an intentional compiler change to the canonical C artifact |

Use the commands from the repository root. Set `ORBIT_CC` or pass `--cc` when the C compiler is not detected automatically.

## Quality Gates

A compiler change is not complete until the relevant gates pass:

1. The self-hosted compiler converges.
2. The canonical C source is current when the change is intentional.
3. The parity probes match their goldens.
4. The behavior suite passes.
5. `fmt --check` is clean on `compiler`, `tests/suite`, `std`, `tests/std` and `examples`, `doctor` reports nothing on `tests/suite`, and `cli_probe` passes.
6. Documentation and examples reflect the supported behavior.

See [Platform Support](SUPPORTED.md#platforms), [Getting Started](GETTING_STARTED.md), and the [Engineering Contract](../ENGINEERING.md) for platform-specific details and invariants.

## Terminal output

The compiler draws its progress and its results in three tiers. The tier is
chosen once per stream, so a redirected stdout with a live stderr gets a plain
result and a styled progress block. `compiler/tools/ui.orb` holds the tiers,
the glyphs and the layout; `runtime/console.c` holds what only the OS can say.

### Tiers

| Tier | Chosen when | Output |
|---|---|---|
| rich | the stream is a console, escapes are enabled on that handle, the console takes UTF-8, the terminal has 256 colors, and none of CI, `NO_COLOR` or `TERM=dumb` is set | Unicode glyphs, rounded cards, `▰▱` stage bars with a violet-to-cyan gradient, animated progress |
| color | the stream is a console with escapes, but UTF-8 or 256 colors is missing | the same layout, static, ASCII glyphs, `[####----]` bars, basic 16-color styles |
| plain | anything else: a pipe or file, `CI`, `NO_COLOR`, `TERM=dumb`, `--color never`, escapes could not be enabled | the output the compiler printed before the tiers existed, byte for byte |

Plain is not a screen of its own. Each command keeps its previous code path and
branches into `ui.orb` only when the tier is not plain. The doctor goldens and
`cli_probe` hold that output and none of them changed with the tiers.

The measured facts come from `orbit_ui_caps(fd)` in `runtime/console.c`. It
returns three bits per stream: console, escapes enabled on that handle (the call
enables them), and UTF-8 output. On Windows that is `GetConsoleMode`,
`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and
`SetConsoleOutputCP(65001)`, so a stream whose mode cannot be set falls to
plain. On POSIX a TTY counts as a console with escapes, and UTF-8 comes from
`LC_ALL`, `LC_CTYPE` or `LANG`.

Truecolor is used when `COLORTERM` is `truecolor` or `24bit`, when
`WT_SESSION` is set, or when `TERM_PROGRAM` is `vscode`, `WezTerm` or
`iTerm.app`. Other 256-color terminals get a six-step ramp. A Windows console
with escapes counts as 256 colors.

### Overrides

| Setting | Effect |
|---|---|
| `ORBIT_UI=rich`, `color`, `plain` | forces the tier on every stream, whatever the terminal says |
| `--color never` | plain |
| `--color always` | skips the `CI`, `NO_COLOR` and `TERM` checks, still needs a console; a pipe keeps the colors it had |
| `--color auto` | the detection above |
| `ORBIT_UI_MOTION=0` | reduced motion: the rich layout with final frames only |
| `ORBIT_UI_MOTION=force` | animates into a pipe; the interrupt probe uses it |

### Screens

- `orbit build` and `orbit run` draw a header and one row per stage on stderr:
  parse, resolve, check, ir, then `native` (R6, link included) or `c` and
  `link`. A bar has 12 cells and is proportional to the slowest stage. The
  result line goes to stdout: output path, total time, `.text` size of the image
  and backend. `run` adds a dim rule before the program's own output.
- Error cards are rounded boxes with `file:line:col`, the message, one line of
  context on each side, a colored underline under the token, the hint after an
  arrow, and the error kind in the bottom edge. Diagnostics without a code or a
  position keep their one-line form.
- `orbit check`, `fmt` and `doctor` end in a card with counts (files, errors,
  warnings, formatted or unchanged) and the time. The per-finding lines and the
  paths printed by `fmt --check` are unchanged.
- `orbit --help`, `orbit --version` and bare `orbit` print a banner and, for
  help, the commands in three groups.

Cards are as wide as the console minus two columns, with the console width
clamped to 40..120 and 80 when it is unknown.

### Motion

In the rich tier with a console on stderr, one thread repaints the build block
about 12 times a second and sleeps on an event between frames. The compiler
passes the whole block as text; byte `0x01` in it becomes the orbital frame and
`0x02` the running milliseconds of the active stage. The calls are
`orbit_ui_anim_start`, `orbit_ui_anim_stage` and `orbit_ui_anim_stop`.

The cursor is hidden while the thread runs. The sequence `ESC[?25h ESC[0m`
restores it on a normal stop, on `exit`, on Ctrl-C and Ctrl-Break (the console
control handler on Windows, `SIGINT` and `SIGTERM` on POSIX) and in the
unhandled-exception filter. While the block is animated, R6's diagnostic is
captured and printed after the block settles.

The thread and the other terminal calls exist only in the runtime built for the
compiler (`ORBIT_WITH_EXEC`). `console.o` is 368 bytes of `.text` in the archive
for user programs and 4360 bytes in the compiler's.

### Preview

```text
orbit build hello.orb -o hello
ORBIT_UI=rich orbit build hello.orb -o hello      # force the rich tier
ORBIT_UI=color orbit build hello.orb -o hello     # the ASCII tier
ORBIT_UI=rich ORBIT_UI_MOTION=0 orbit check bad.orb
ORBIT_UI=plain orbit build hello.orb -o hello     # the old output
```

### Snapshots

`scripts/doctor_gates.py snapshots` runs twelve screens in the rich tier
(`ORBIT_UI=rich ORBIT_UI_MOTION=0`, truecolor) and in the color tier
(`ORBIT_UI=color`) and compares them with `tests/ui/<screen>.<tier>.txt`.
Escape sequences stay in the files, so a changed color is a changed snapshot.
Times, sizes and the cells of a bar vary between runs and are masked.

```text
python scripts/doctor_gates.py snapshots --compiler <orbit> --cc <gcc>           # check
python scripts/doctor_gates.py snapshots --compiler <orbit> --cc <gcc> --update  # rewrite, then read the diff
```

The same subcommand runs an animated build of `compiler/host/main.orb`, sends it a
console break and requires the stream to end with `ESC[?25h ESC[0m`. It reports
"skipped" when the platform offers no console to send the break to. `dev.py`
runs it as the `ui_snapshots` gate in tier 1.

## orbit doctor checks

`orbit doctor` looks over your `.orb` files and reports what it finds. It
does not change your code unless you ask it to with `--fix`.

```sh
orbit doctor                  # scan the current directory
orbit doctor examples         # scan one directory tree
orbit doctor --fix            # scan, then apply the fixes it knows
orbit doctor --fix --dry-run  # say what it would change, change nothing
orbit doctor --quiet examples # findings only, no summaries
orbit doctor --verbose .      # also the per-phase timings
orbit doctor --only D006,D007 # just these checks
orbit doctor --skip D003      # everything but this one
orbit doctor --min-severity error   # hide warnings
orbit doctor --baseline known.txt   # print what is listed, do not fail on it
orbit doctor --format json examples  # findings as JSON on stdout
orbit doctor --color always examples # force ANSI colors
orbit doctor --help           # usage
```

With `--format json`, stdout is a JSON array of objects and nothing else
(exit codes unchanged), so editors and CI can parse it. The original six
keys are a contract and are always present:

`{file, line, code, severity, message, fix}`

Four more keys are additive, and mean a finding can be acted on without a
human reading it:

| Key | What it is |
|---|---|
| `column` | 1-based column, or `0` when the finding is about a whole line or the whole file. |
| `layer` | Which analysis produced it: `text`, `ast`, `ir` or `sema`. |
| `fix_kind` | `safe`, `unsafe` or `""` when there is no fix. |
| `applied` | `applied`, or a sentence saying why not, after a `--fix` run. |
| `edits` | The fix as line ranges: `{start_line, end_line, kind, text}`. `end_line` exclusive when it is `start_line - 1`, that is, an insertion in front of that line. A consumer can apply them itself. |

Reading `edits` is a supported interface, not a dump: a check that can fix
itself always emits them, and `applied` says whether doctor managed to.

### Presentation

Every finding carries a severity: `error` for `D001` (no toolchain)
and `D008` (the file does not parse, or it does not pass the semantic
checks), `warning` for the
rest. Doctor stops before the IR verifier that `orbit check` and `orbit build`
run, so a file refused there is not a `D008`:
`tests/negative/n100_object_field_untyped_read.orb` reports no findings under
`orbit doctor` (exit 0), and both `orbit check` and `orbit build` refuse it
(exit 1). That gap is open in [the defect index](internals/DEFECTS.md). The text line reads `file:line severity [CODE] message fix:
action`, with the location bolded, the severity red/yellow and the
code cyan when colors are on. Paths print relative to the scanned
directory when possible. Colors follow `--color always|never|auto`
(`auto` honors `NO_COLOR` and `TERM`, and stays plain on consoles
that do not advertise themselves). `--format json` never colors.

Exit codes: `0` means clean, `1` means there are findings, `2` means the arguments were not understood.

### Checks

Every finding prints `file:line`, a code, and a one-line fix, for example:

```text
app.orb:12 [D002] route GET /users/:id collides with app.orb:8 (GET /users/{id}); both normalize to /users/:param. fix: merge the handlers or give the paths distinct shapes.
```

| Code | What it reports |
|---|---|
| `D001` | No C compiler answered. Doctor tries `ORBIT_CC`, then `CC`, then `gcc`, `clang`, `cc` in that order - a wider net than the build, which resolves `ORBIT_CC`, `CC`, `cc` and stops. |
| `D002` | Route conflicts inside one program: exact duplicates, paths that match once `:params` and `{params}` are treated alike (so `/users/:id` and `/users/{uuid}` collide), and specific routes covered by a same-method wildcard. A file belongs to the programs whose import closure reaches it, so two independent services that both serve `GET /health` are not a finding. |
| `D003` | A `private fn` that nothing in the scanned files calls. Public functions are never reported here, since files outside the scan may import them. `main` and `extern` functions are never reported. |
| `D004` | A `model` that nothing in the scanned files references, including use as a type or through calls such as `Product.all()`. |
| `D005` | An unknown member on `system`, for example `system.cores()`. The valid members are `uptime`, `pid`, `active_workers`, `http_requests_total`, `http_requests_ok`, `http_requests_error`, `latency_avg_us`, `latency_p50_us`, `latency_p95_us`, `latency_p99_us`. |
| `D006` | Trailing whitespace on a line. |
| `D007` | A file that does not end with a newline. |
| `D009` | A string literal that looks like a hardcoded credential (`sk-`, `ghp_`, `AKIA`, `-----BEGIN`, `password=`, `secret=`, `token=`, `apikey=`). **The value is never printed**, only the matched prefix: a diagnostic that quoted the string would copy the credential into CI logs and every terminal that ran the tool. A literal must have real content after the prefix, so the check does not flag its own prefix table. |
| `D010` | A SQL statement (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `DROP`) built by string interpolation. A keyword alone is not a finding, and only the closing line is inspected, so this under-reports rather than guessing. |
| `D011` | A `POST`/`PUT`/`PATCH`/`DELETE` route that returns without a role guard or a request validation block. Reads the runtime's own guard vocabulary (`orbit_auth_*`, `req.body`, an early-returning `if`), so a route guarded through a helper is not reported -- it under-reports rather than guess. |
| `D012` | An import whose module is named nowhere, directly or through what that module itself imports. The transitive part is the rule the check depends on. Without it, removing the flagged imports from `std/io/io.orb` broke both files at the very next build. |
| `D014` | A database query inside a loop: one round trip per iteration where one per request was meant. |
| `D015` | A **string** built by `+` inside a loop over a collection, so the whole prefix is copied every iteration. It requires the accumulator to be known to be a string -- `sum = sum + items.get(i)` over ints is the same pattern and costs nothing, and reporting it put 32 findings into `std/` and `tests/suite/`. Advisory: the scope gate prints it and does not fail on it, because a test whose purpose is to assert `joined` produces `"red,blue,"` cannot also be told to stop concatenating. |
| `D016` | A bare number of three or more digits that appears twice in a file under a name that says nothing about what it is. Keyed on the NUMBER, not on number-and-name: the same timeout written under two vague names is one constant hiding in two places. |
| `D017` | Cyclomatic complexity: base 1 plus one per `if`, `while`, `for`, match arm and `try`. 11-20 is a warning, over 20 is an error. Advisory in the scope gate, because a test whose `main` asserts fifteen behaviours IS complexity 20 and the advice would be about the test. |
| `D019` | An allocation inside a loop, so it is repeated on every iteration. Matches the runtime's allocating constructors by name. An empty list literal is exempt: `var acc = []` inside a loop is how an accumulator is written, and hoisting it would be wrong. |
| `D022` | Two match arms binding the same variant, so the later one is dead. The first matching arm wins, so the duplicate never runs. Compared on the fully qualified pattern, so `Foo.Bar` and `Baz.Bar` cannot collide. `_` is not a variant and is skipped. |
| `D027` | A call that returns a `result`, called as a statement. The error is discarded and the program continues as if the call had succeeded. Only statement position counts: bound to a `val`, returned, or handled by `try ... catch` are all silent. Needs the callee's declared return type, which is why `DoctorDecl` carries one. Scoped to `result` on purpose -- a discarded `int` is sometimes deliberate. |
| `D028` | A `var` whose last write nothing reads afterwards, so the value it holds is never used. One finding per name per function. `val` is silent: a `val` has one write and is not a mutable store. A write inside a loop body is silent, and that is a real limit rather than a hedge: `var p = 1; while k < 16 { use(p); p = p * 2 }` reads `p` on the next iteration, and a single linear pass cannot see it. Proving otherwise needs a fixpoint over the loop, which is not this check. Walking the loop body before its condition matters for the same reason -- the condition has the last word, because that is when it runs. The receiver of a method call counts as read: `pick(xs, bare).len()` parses as `Call(callee: MemberAccess(object: Call(...)))`, so reading only the argument list loses the receiver's own arguments. `var mut` is reported: stating the intent to reassign does not make the value read. The left side of an assignment is a write only when it is a bare name; `xs[i] = 7` and `tmp.v = n` write through a place and read everything inside it, `i` and `tmp` included. The item of a `for` and the bindings of a `match` arm are never tracked: they are re-bound every iteration, which is the same reason loop writes are silent. Reaches `fn` and `route` bodies; `extern fn` is skipped. |
| `D025` | A value read from the request reaching a database call. Sources are `orbit_http_body_get`, `orbit_auth_bearer_token` and `orbit_auth_current_role`; sinks are the six `orbit_db_*` query entry points. Taint is direct and per function or route body: a name is tainted when bound to something containing a source or a tainted name, and stops when rebound to something containing neither. Reported on the sink call, which carries a position. |
| `D023` | A name shadowed in an inner scope and read again after that scope closes. The read returns the INNER value, because the emitted C declares one variable per name. Shadowing alone is not reported: the repository contains nineteen and all are correct. One finding per name per function, because sibling blocks that each redeclare it produce the same location and the same sentence. Reaches `fn` and `route` bodies, statements and expressions including value-position `if`/`match`/`try` and model literals. It does not reach D017-D021's route gap: those take a `FunctionDeclNode`, so routes are still unexamined by them. |
| `D021` | A function parameter its own body never reads. `extern fn` is skipped, since those bodies are empty by construction and the parameter is documentation. Reported on the `fn` line: the parser keeps parameter names but not their positions. |
| `D018` | A function that calls itself where the call is not the value it returns. `return self(n)` is tail; `return 1 + self(n)` is not, and holds a frame per level. Advisory for the same reason as D017: `tests/suite/fn_recursive.orb` exists to test recursion. |
| `D013` | A `var` that is never assigned again. A `var` exists because something changes it; this one is a `val` wearing a `var`. `var mut x` is never reported, because `mut` is an explicit statement of intent. Assignments must actually look like `name =` or `name +=`; `==`, `<` and `!=` are comparisons, and a bare *use* of the name is a read, not a write. An annotated declaration is its own write: `var x: int = 0` with nothing after it is reported, pinned by `tests/doctor/golden/d013_annotated_var_never_reassigned`. |
| `D008` | A file the compiler could not accept: it does not parse, or it does not pass the semantic checks. Both halves are reported separately, because they have different causes and different fixes. |

Unused reports (`D003`/`D004`) are deliberately conservative. A name counts as used when the compiler's AST walk finds it or when a whole-word use appears anywhere outside its own declaration line, so generated or loosely referenced code is left alone. If doctor stays quiet about a helper you suspect is dead, it is erring on the side of not bothering you.

A few notes on scope:

- Doctor scans `.orb` files under the given directory, recursing into subdirectories. Files and directories whose names start with a dot are skipped.
- A scanned tree is treated as one project: routes and declarations in
  different files are checked against each other. A directory of
  independent services (like `examples/`) therefore reports cross-service
  findings (e.g. two services both defining `GET /health`). Scan a single
  service directory or file when that is what you mean.
- If the path you pass ends in `.orb`, doctor treats it as a single file.
- When a file does not parse, doctor still runs the text-based checks (routes, `system.*`, whitespace) on it and skips only the AST-based unused analysis for that file.

### --fix

`--fix` applies the fixes doctor knows how to make, which today are the two
whitespace tidies:

1. trailing-whitespace removal per line,
2. a missing final newline at end of file.

It never renames, moves, deletes, or restructures code, and it never touches
route, model, function, or `system.*` findings. The exit code then reflects
the state after fixing, so a clean `--fix` run exits `0`.

Every fix goes through one engine, and that engine holds three promises:

- **Nothing outside the edited range changes.** Fixes splice into the original
  text by offset. A file that is fixed on line 900 is byte-for-byte identical
  everywhere else, including its line endings: a CRLF file stays CRLF, and no
  comment is reflowed.
- **Two fixes to one line is a conflict, not a guess.** If two findings both
  rewrite the same line, doctor applies neither and says so, rather than
  merging them into something neither check asked for.
- **A fixed file is verified before it is written.** The front end is always
  re-run on the result. With `--fix` the C step runs too, unless you pass
  `--fast`. The result is only written if both pass.

`--unsafe` extends `--fix` to fixes marked `unsafe` (structural ones). No
check emits those yet. The flag exists so that the day one does, the safe path
is the default rather than the other way round. `--dry-run` reports the fix
and its verification without writing anything.

### Adopting new checks

A new check arrives as an error, which breaks every tree that has the problem.
That is what the baseline is for:

```sh
orbit doctor --baseline known.txt .   # report, but do not fail on what is listed
```

Each line of the baseline file is `CODE file:line`, and a finding that matches
one is printed and marked `(in baseline: known finding, not counted toward
the exit code)` instead of failing the run. Delete a line once you have fixed
it, so the baseline only ever shrinks.

`scripts/doctor_gates.py doctor` pins the exact output of each check against the
goldens in `tests/doctor/golden/`, so a check cannot quietly change what it
says.

### What doctor remembers

The semantic half of `D008` runs the real typechecker, and that is the slowest
thing doctor does. Its answer is cached on a **hash of the file's contents**:

- a file you have not touched, and none of the modules it imports, is not
  typechecked twice
- a file you edited, even by one byte, is typechecked again
- **a module you edited is followed through to every file that imports it**,
  directly or not

That last one is the whole reason the key is a fingerprint and not a hash: the
semantic check resolves and typechecks the import closure, so the answer belongs
to the file *and* everything it pulls in. A per-file cache key reported files
clean that `orbit check` rejected, which is the worst thing a linter can do.

```sh
orbit doctor .                                  # no cache: every file is checked
ORBIT_DOCTOR_CACHE=/tmp/mycache orbit doctor .  # cache answers here
```

The cache is opt-in. With a directory named, the first run on a fresh clone
pays for every file and later runs on the same tree do not. It is off by
default because its key is a file's source and import closure, which cannot see
the compiler that answered: a directory written by an older build answered "ok"
for a file the current compiler rejects on 2026-11-06, and the finding
disappeared. Start from an empty directory after changing the compiler. One
consequence is worth knowing either way: a cached answer does not reprint the
compiler's diagnostic, so that finding points you at `orbit check <file>` for
the detail instead of showing it above the line.

### Order of findings

Findings are printed by the phase that produced them, not grouped by file: the
text checks first, then the semantic check (`D008`). That is a consequence of
the parse pass being shared — the fingerprint of one file depends on the imports
of another, so the semantic pass has to come after the whole tree is parsed.
Every finding is still reported, and the order is pinned by the goldens.

A file that does not parse is reported by the parse pass and is not typechecked
at all, which is why a syntax error no longer also produces a semantic error:
there is nothing to typecheck yet.

### Which directories are gated

A raw `orbit doctor <dir>` reports findings that the gate is right to ignore.
Measured on 2026-11-01, one run per directory, over the six directories git
tracks:

| directory | findings | what they are |
|---|---|---|
| `compiler/` | 139 | advisory: `D017` 78, `D018` 31, `D015` 29, `D019` 1 |
| `std/` | 5 | advisory: `D015` 3, `D017` 2 |
| `tests/` | 282 | `D008` 129 (fixtures that must NOT compile), then `D017` 32, `D013` 17, `D007` 15, `D021` 12, `D006` 12, `D023` 11, `D019` 8, `D002` 1 |
| `examples/` | 3 | `D004` 2 (unused models), `D013` 1 |
| `runtime/` | 2 | `D008` 2 (must not compile) |
| `scripts/` | 4 | `D013` 3, `D017` 1 |

That is 435 findings, and almost none of them is something to fix. The gate
names what must be clean instead of baselining the rest.
`scripts/doctor_gates.py doctor --scope-only` runs doctor over `compiler`, `std` and
`tests/suite`, and those three produce nothing outside the advisory codes.
Four dead models came out of making that true: `IRTraitMethod` and `Loc` in the
compiler, `JwtHeader` and `JwtToken` in std.

`examples/` is deliberately not in the list. It is a directory of
**independent services**, and what remains there is per file: two unused models
and one mutable route. Route conflicts are no longer among them. `D002`
compares two routes only when one program's import closure reaches both files,
so five services' `GET /health` handlers are five programs' routes. Within one
program the check still fires: `tests/doctor/` is a two-file program, and
`scripts/doctor_gates.py cli-probe` pins both halves.

Two limits of the walk. A directory whose name begins with a dot is tool state
and is skipped, so `.orbit/` with its thousands of build copies is never
scanned. An untracked `scratch/` is not skipped, and a generated 417 KB file
with ten thousand functions exhausts the default 6 GB arena before the scan can
report anything; scan the tracked directories, or drop the generated file.

### Reading production telemetry

A running service records a per-route ledger: request counts, p50/p95/p99, a
latency histogram, the arena footprint of the route's requests, and an energy
estimate. Until now it was reachable only at
`/_ledger/data`, on loopback, over HTTP -- which means a static tool could not
read it. It would have to start a server, drive traffic through it and know when
to stop. The interesting cases only exist *after* the service has been up: "this
route has never been requested" is not knowable from a fresh process.

Set one environment variable and the service writes the same JSON to a file at
exit:

```sh
ORBIT_LEDGER_OUT=/tmp/ledger.json ./my_service
```

The file is written atomically (temporary plus rename), so a reader sees the old
snapshot or the new one and never half of one. With the variable unset nothing
happens and there is no cost. `runtime/test_ledger_percentiles.c` covers the
hook, the rename, and the opt-in default.

#### Checks that carry a production number

| Code | What it reports |
|---|---|
| `D031` | A route the source registers that the ledger has **no record of**. Dead code that reading the source cannot find: `D003` says "nothing in the scanned files calls this", which is a different and weaker claim than "no request has ever reached it". |
| `D032` | A route whose **arena overflowed** -- `arena_overflow` non-zero in the snapshot: requests that needed more arena than the segment reserved, so the allocator chained another. Counted per request from the arena in `orbit_ledger_exit`, so this is a leak counted in production, not inferred from reading allocations. The column is real but narrow: the default admission lease caps a request at 16 MB (`orbit_admission_lease_create_for_route`, `runtime/admission.c`), below the arena's 64 MB reservation, so an admitted request cannot chain a segment and this check is structurally silent under the default policy. It fires where the lease does not bind -- `ORBIT_ADMISSION=0` or a budget above the reservation. |
| `D033` | A route whose **measured p99 exceeds the budget** in `ENGINEERING.md`. The budget is a claim about production and this is production disagreeing with it. |

These read a snapshot. They are silent without one, which is not "assume the
best" but "a check that reports production problems with no production data is
guessing, and a guess here cannot be acted on or refuted".

```sh
orbit doctor . --telemetry /tmp/ledger.json     # or just set ORBIT_LEDGER_OUT
orbit doctor . --skip D031                       # not for you
```

The budget is read out of `ENGINEERING.md` rather than hard-coded, so the check
and the document cannot drift apart. Change the document and the check follows.
`--budget-doc` points at a different copy, which is how the goldens run from a
throwaway directory. No budget found means `D033` stays off, rather than
inventing a threshold.

### Gates

Doctor prints the contributor gate commands at the end of every run for reference. It never runs them itself.

```sh
python scripts/trust.py verify --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/corpus_gates.py parity --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/corpus_gates.py suite --cc <gcc-or-clang> --compiler <path-to-orbit>
```

Run those from the repository root when you change the compiler. See `docs/COMMANDS.md` for the full command reference.
