# Supported platforms and versions

## Platforms

This page covers the supported paths for the current self-hosted compiler.

### Support Matrix

| Platform | C compiler | Python | Compiler build | Runtime target |
|---|---|---|---|---|
| Windows x86-64 | Clang, MSVC, or GCC | Python 3.10+ | Supported | Supported |
| Linux x86-64 | GCC or Clang | Python 3.10+ | Supported | Supported |
| macOS | Clang | Python 3.10+ | Supported by the POSIX scripts | Supported by the POSIX scripts |

The primary compiler workflow needs nothing but a C compiler and a stock `python3`.

### Required Tools

- A C compiler available on `PATH`.
- Python 3.10 or newer.
- Git when building from a checkout.

Compiler selection in the build follows this order:

```text
ORBIT_CC -> CC -> cc
```

That is `compiler/host/pipeline.orb` and nothing else. `orbit doctor` is the one
exception: it reports a finding when no compiler answers, so it also probes
`gcc` and `clang` off `PATH` - see [orbit doctor](COMMANDS.md#orbit-doctor-checks).

Set `ORBIT_CC` when the compiler is not discoverable or when a specific compiler must be tested.

#### Windows PowerShell

```powershell
$env:ORBIT_CC = "clang"
python scripts/trust.py build --cc $env:ORBIT_CC --out orbit.exe
```

#### Linux or macOS

```sh
export ORBIT_CC=clang
python3 scripts/trust.py build --cc "$ORBIT_CC" --out orbit
```

### Optional Tools

| Tool | Used for |
|---|---|
| VS Code | Editor extension and syntax support |
| `curl` | Readiness polling before a live gate, and manual request checks |
| `python3` (standard library only) | Every gate script; no third-party packages are needed |

None of these are required to build, verify, install or release Orbit. `scripts/kynx_gate.py load` and `scripts/measure.py measure-selfhost` are stdlib-only on purpose, so a measurement never depends on a package install.

### Database Notes

SQLite-backed programs require the runtime database support and the appropriate SQLite artifact:

- Linux and macOS use the system SQLite development library.
- Windows uses the bundled files under `runtime/vendor/win-x64/`.

A project that does not use database features can use the compiler without SQLite development support.

### Installation Scripts

From the repository root:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

```sh
# Linux or macOS
bash scripts/install.sh
```

The installers prefer a released fixed-point binary when one is present. Otherwise they build the compiler from the committed canonical C source, install it under `~/.orbit/bin` or `%USERPROFILE%\\.orbit\\bin`, update the user PATH, and register the VS Code extension.

### Support Policy

A platform is supported when its documented compiler path passes the self-host, fixed-point, parity, and behavior-suite gates in CI or in an equivalent local environment. Performance numbers are not portable guarantees. They must carry the hardware, operating system, compiler, workload, and measurement procedure.

## Versions and compatibility

This section defines how Orbit versions the language, compiler, runtime and standard library. It is conservative while the public contract is still coming together.

### Version Format

Orbit releases use:

```text
MAJOR.MINOR.PATCH[-pre-release]
```

Examples:

- `0.1.0` is the first versioned development release.
- `0.1.0-rc.2` is the second release candidate for `0.1.0`.
- `1.0.0` marks the first release under the stable compatibility policy.

Pre-release identifiers are ordered after the base version. A release candidate is not a promise that every planned feature is complete. It means the contents of that candidate are being evaluated for the named release.

### Components

The compiler, runtime, and standard library are released as one Orbit distribution. They share the same version number unless a release note explicitly states otherwise.

The version applies to:

- the Orbit compiler executable.
- the generated-code contract used by the compiler.
- the bundled C runtime.
- the standard library modules.
- the documented command-line interface.

The canonical C seed and fixed-point verification artifacts are implementation and release artifacts. They do not receive an independent public version.

### Compatibility Levels

#### Patch releases

A patch release may contain:

- bug fixes that preserve accepted source behavior.
- diagnostic improvements that do not change successful compilation.
- runtime fixes that preserve the documented API.
- documentation and build reproducibility fixes.

#### Minor releases

A minor release may contain:

- new language syntax or library APIs.
- new runtime capabilities.
- new diagnostics and opt-in configuration.
- behavior changes required to correct an undocumented or unsafe implementation defect.

Existing documented programs should continue to compile unless a release note identifies a compatibility exception.

#### Major releases

A major release may contain:

- removal or incompatible changes to documented language behavior.
- changes to the generated-code or runtime ABI that require source or build changes.
- changes to memory, error, concurrency, or ownership semantics.
- removal of documented command-line options.

The project remains in the `0.x` series while these contracts are being stabilized. During this period, minor releases may include carefully documented breaking changes that would require a major release after `1.0.0`.

### Release Candidates

A release candidate must identify:

- the compiler and runtime revision.
- supported platforms and C compilers.
- known limitations.
- verification results for bootstrap, fixed point, parity, and behavior tests.
- changes since the previous candidate.

A candidate must not be described as stable when an open issue can silently miscompile valid source, invalidate the fixed point, or make a documented runtime operation unsafe.

### Compatibility Policy

Documentation is the source of the public compatibility contract. Internal compiler modules, generated C layout, and experimental features are not stable APIs unless explicitly documented as such.

When a change affects documented behavior, the same change should update:

1. the language reference or runtime documentation.
2. an executable example or regression test.
3. the release notes.
4. the fixed-point and parity artifacts when compiler source changes.

See [Command Reference](COMMANDS.md) for the verification commands and [Engineering Contract](../ENGINEERING.md) for the invariants that govern compiler changes.

## Toolchain

tcc 0.9.27 is the fast-build toolchain: it compiles a translation unit in a
fraction of gcc's time and is therefore the right tool for single-file
probes and edit-compile-run loops. It is not a reference toolchain. Two
rules draw that boundary, and both are mechanical consequences of what
tcc 0.9.27 can and cannot do, measured on 2026-10-14 (Windows 10
19045, AMD Ryzen 5 2400G, gcc 16.2.0 w64devkit, tcc 0.9.27 x86_64
Windows portable). Nothing below is a guess: every gap has a probe that
fails without the shim and passes with it.

### Rule 1 — tcc never produces a quoted number

No benchmark, performance comparison, latency percentile, or energy /
power figure may come from a tcc-built binary. Not as a headline, not
as a baseline, not "just to see". Three independent reasons:

1. Its codegen is unoptimised by design. A timing compares tcc's
   codegen against the other toolchain's, not the two programs.
2. The shim's `YieldProcessor` is `Sleep(0)`, a timeslice yield, not a
   pause hint — spin behaviour under tcc is not the shipped behaviour.
3. The shim's `GetTickCount64` is the 32-bit `GetTickCount` and wraps
   every ~49 days. Any clock arithmetic past a restart is wrong.

Instruments that stay on the reference toolchain: `scripts/kynx_gate.py
load`, `scripts/measure.py measure-selfhost`, the `/_ledger` energy columns.
`docs/internals/PERF.md` and `docs/internals/ENERGY.md` record what those instruments say.
A tcc timing belongs in neither file.

### Rule 2 — the multithreaded server always builds with gcc

`runtime/thread_pool.c` needs `__atomic` builtins, `performance.h`
needs 64-bit interlocked imports, and several runtime TUs need
thread-local storage. tcc 0.9.27 on Windows has none of the three:

| Need | Under tcc 0.9.27 | Appears in |
|---|---|---|
| `__atomic_load_n` / `__atomic_store_n` | undeclared, hard compile error | `thread_pool.c` acceptor/worker rings |
| `InterlockedIncrement64` / `InterlockedExchangeAdd64` | declared by tcc's `winbase.h`, missing from its `kernel32.def`: `undefined symbol` at link | `performance.h` counters, `arena_pool.c`, `admission.c` |
| `__thread` / `__declspec(thread)` | rejected by the parser | `ORBIT_THREAD_LOCAL` (`performance.h`), `crt_compat.h` env slot |
| `pthread.h` | include not found | POSIX-only test helpers |

So a tcc build of any threaded TU fails loudly at compile or link
time, and the server build stays gcc (Linux) / clang (Windows CI).
`tcc_setup.py` and the shim never try to close these gaps: a forked
import lib for the 64-bit interlocked calls would make tcc build code
whose atomics no gate verifies, which is worse than a loud failure.

### Platform matrix

| Platform | tcc story | How |
|---|---|---|
| Windows x64 | portable 0.9.27 + `vendor/tcc-shim/` | `python scripts/tcc_setup.py` (zip pinned by SHA-256, no admin); `-I vendor/tcc-shim -include tcc_toolchain.h` + `ws2_32.def` / `sqlite3.def` |
| Linux x64 | system tcc, no shim (system headers are complete) | package manager (`sudo apt-get install -y tcc`, …); `tcc_setup.py --check` enforces the 0.9.27 pin and refuses anything else |
| macOS ARM64 | no stable tcc (0.9.27 has no ARM64 backend; the mob branch is unpinned) | documented fallback: gcc/clang. `tcc_setup.py` exits SKIP saying so |

### What the shim covers (and how it was verified)

- `winsock2.h` / `ws2tcpip.h`: 29 functions with ABI-real structs and
  SDK values. Every import name confirmed as a real `ws2_32.dll`
  export via `tcc -impdef` (197-export dump, same date).
- `tcc_toolchain.h` (`-include`): `GetTickCount64`→`GetTickCount`
  (tcc neither declares nor imports the 64-bit one),
  `YieldProcessor`→`Sleep(0)` (tcc's spelling resolves to an
  unimplemented `_mm_pause`), `strtoll`→`_strtoi64` /
  `strtoull`→`_strtoui64` (tcc declares the former pair but imports
  only the latter). All `__TINYC__`-guarded so gcc/clang builds are
  unaffected.
- `ws2_32.def` / `sqlite3.def`: minimal import libraries. The ws2 set
  is exactly the 29 header functions. The sqlite set is exactly the 19
  `sqlite3_*` symbols `runtime/database.c` and
  `tests/auth/auth_harness.c` use, each confirmed as a real export of
  `runtime/vendor/win-x64/sqlite3.dll`.

Verification, all in throwaway dirs (never in the repo):

| Build | Command form | Result |
|---|---|---|
| socket + toolchain mappings | `tcc -I vendor/tcc-shim -include tcc_toolchain.h probe_socket.c ws2_32.def` | clean compile, `TCC-SHIM-SOCKET-PASS` at runtime (ephemeral-port loopback: non-blocking connect, select, `SO_ERROR`, accept, send/recv) |
| same probe, gcc + real SDK headers | `gcc probe_socket.c -lws2_32` | same `TCC-SHIM-SOCKET-PASS`: behavioural equivalence, not just "it links" |
| sqlite wrapper | `tcc -I runtime/vendor probe_sqlite.c sqlite3.def`, `sqlite3.dll` beside the exe | `TCC-SHIM-SQLITE-PASS` (`:memory:` create/bind/select/close) |
| negative: `gethostname` (real export, outside the 29) | same flags | `undefined symbol` at link — the closed set holds |
| negative: `__atomic_load_n` | bare tcc | undeclared, hard error — Rule 2's backing |

Re-run the two positive probes after any shim change. They live at
`vendor/tcc-shim/probe_socket.c` and `vendor/tcc-shim/probe_sqlite.c`.
CI runs them on Windows and skips this step cleanly (visible `TCC-SKIP`,
never a silent pass) where tcc is unavailable.

One near-miss worth recording: during validation the shim briefly
defined `WSAEWOULDBLOCK` as 14035 from memory, and the loopback probe
failed. The DLL, MinGW-w64's `winerror.h` (`WSABASEERR+35`), and tcc's
own `winerror.h` all say 10035 — three sources agree.
The shim carries 10035, and the memory lost.

## Frequently asked questions

Short answers, plain words. Where the answer is "not yet" or
"not known," it says so - that's the point of this page.

### Basics

**1. What is Orbit?**
A statically typed language for APIs and microservices. It
compiles fast and needs little to run, so it stays fast even
under load. The project tests whether servers can do the
same work with less energy. How far that goes is still
being measured.

**2. Is Orbit ready for production?**
No. It's 0.1.0 pre-release research. Reads, writes, bearer auth,
path parameters and forward migrations all work. What isn't there
is multi-host clustering, `down` migrations and a language server.
Uploads save files, but a binary payload doesn't round-trip as a
string. Latency percentiles are estimated inside their histogram bucket, and
requests split by class (`system.http_requests_ok()` and
`http_requests_error()`). Good for learning and experimenting. Don't bet
a business on it.

**3. What do I need to build it?**
A C compiler (gcc, clang, or MSVC), Python 3.10+, and git.
That's it - no giant dependencies. See [Getting Started](GETTING_STARTED.md).

**4. How is this different from Go, Rust, or Node?**
There is no comparison against other languages by claim -
only with same-machine, same-workload measurements,
published with method. Those measurements don't exist yet
in publishable form. What can be said without one: Orbit
compiles to readable C99, reclaims memory per request with
arenas, and measures its own resource use out of the box.

**5. Is Orbit "green" / eco-friendly?**
It's an engineering project whose result could be less energy
per request - not an ecological identity. Energy savings
are not claimed until they're measured with hardware,
workload, and method recorded. Anyone telling you otherwise
about 0.1.0 is ahead of the data.

### Language

**6. What can I build today?**
Read-heavy JSON services over SQLite: routes, query values,
request bodies, filtered queries, status codes, live telemetry.
The [Tour](GETTING_STARTED.md#a-thirty-minute-tour) takes 30 minutes. The tutorials go further.

**7. What can't Orbit do yet?**
The known list: multi-host clustering, `down` migrations, a
language server, joules on Windows (no sensor - CPU time plus
memory is the proxy), graceful drain on Windows (the stop is a
kill), and a success/error split in the latency percentiles.
Multipart uploads and forward migrations used to be on this list
and work now. Full list with workarounds:
[Known Limitations](internals/LIMITATIONS_LOG.md).

**8. When does `create()` return `false`?**
When the `id` already exists - it is the primary key - or when
the payload has no usable fields. `delete()` answers `false`
when no row was removed, which is how a handler tells a 404 from
a write. Code both branches. They're real answers, not filler.

**9. Is the language stable? Will my code compile next month?**
No stability promise before 1.0. Minor releases in the 0.x
series may include documented breaking changes (see
[Versioning](SUPPORTED.md#versions-and-compatibility)). Pin your compiler version in CI.

**10. Does Orbit have generics / async / pattern matching?**
Functions and models take inferred type parameters (`fn getOr[T]`,
`model Box[T]`). Unions and `match` cover tagged alternatives. There is no
`async fn` and no `every` schedules -- both parse and are refused, because
there is no async or timer runtime behind them. Collection APIs,
concurrency ergonomics, and module imports are still settling.
Keep business logic simple, cover it with tests, and file an
issue when you hit a wall - every report is read.

### Running services

**11. How do I set the port?**
Declare it in the entry file - `port 8080` - and the built server binds it
when started with no argument. `./service 8080` still overrides the
declaration. With neither, the default is 3000. The declared value must be
an integer literal in 1..65535. Anything else fails `orbit check` (E1008).

**12. Where's the database file?**
`.orbit/data/app.db` under the project directory, created on
first start with four tables and demo seed rows. Back it up by
copying the file while the service is stopped. A legacy `./orbit.db`
from older builds is moved there once, loudly, by `orbit start`/`orbit dev`.

**13. Why did my DB service exit with no message on Windows?**
`sqlite3.dll` must sit next to the exe. Copy it from
`runtime/vendor/win-x64/`. Non-DB services don't need it.

**14. How do I run two copies?**
`orbit cluster up --nodes 2 --port-base 8100 --service
service.orb` - single host only, no failover. Verified walkthrough:
[Deploy tutorial](tutorials/deploy-single-binary.md).

**15. How do I know it's healthy?**
`GET /health` if you write one, process liveness via
`cluster status`, and the built-in request ledger at `/_ledger`
(JSON at `/_ledger/data`, loopback only). A `/metrics` endpoint is
yours to write - `examples/health_service.orb` is one. There are no
built-in alerts or dashboards.

### Measuring

**16. Is Orbit faster than X?**
Not known yet in any publishable sense. There is no
cross-language measurement of Orbit against anything, so
none is implied here. Ask again after someone
publishes a run with the hardware, the flags, the workload
and the spread.

**17. What does "stays fast under load" mean concretely?**
Today: admission control sheds load (429s past budget)
and per-request arenas bound memory growth. With numbers and
method attached - otherwise it's just words, and words
are not evidence.

**18. Can I measure energy per request?**
On Linux with RAPL or a wall meter, yes, following the guide.
On Windows, no joules - report CPU time and memory as labeled
proxies. The docs never convert one to the other.

### Project

**19. Who builds Orbit, and why should I trust it?**
Orbit is maintained by one person, in Argentina, on modest
hardware - which is the point: the constraint is the design
brief. Trust comes from the verification gates (bootstrap,
parity, behavior suite all in CI) and from publishing
limits next to features, not from a claim.

**20. How can I help?**
Run the [Tour](GETTING_STARTED.md#a-thirty-minute-tour), file issues with repros (small `.orb`
files plus expected vs actual), and grow the behavior suite -
one focused test per behavior. Start with
[Contributing](../CONTRIBUTING.md). Bug reports with failing
examples help more than feature requests right now.
## What is not supported yet

The list below is what a program cannot rely on today. Each item links to the
measurement, its date and its command in
[the dated record](internals/LIMITATIONS_LOG.md).

- **No language server.** `editors/vscode/` highlights the language and runs
  `orbit check` on save; there is no diagnostics server, completion or
  navigation ([measured](internals/LIMITATIONS_LOG.md#an-editor-gets-checks-on-save-not-a-language-server)).
- **`orbit cluster` is single-host.** It starts N copies of one service on this
  machine: no shared state, no proxy, no failover ([measured](internals/LIMITATIONS_LOG.md#cluster-is-single-host-only)).
- **Energy is measured only where sensors exist.** Joules come from Linux RAPL;
  on Windows the ledger reports CPU time and memory instead
  ([measured](internals/LIMITATIONS_LOG.md#no-joules-on-windows)).
- **Writes cover the measured set.** `Model.create`, `update` and `delete`
  report whether they changed a row, and a duplicate primary key or a missing
  table is `false`; constraints and ad-hoc DDL outside that set are not
  measured ([measured](internals/LIMITATIONS_LOG.md#writes-work-but-duplicates-and-missing-tables-fail)).
- **Generic inference is one rule, not a solver.** `Box { v: 1 }` instantiates
  from the value written for the field that uses `T`; a parameter written as
  `Box` with no argument does not infer one
  ([measured](internals/LIMITATIONS_LOG.md#a-generic-model-monomorphises-an-expression-infers-the-argument-a-signature-writes-it)).
- **`orbit doctor` fits the machine and skips tool state.** One process
  typechecks the tree it walks, so the scan has to fit the ceiling on committed
  bytes; dot-directories and what `.gitignore` names are not scanned
  ([measured](internals/LIMITATIONS_LOG.md#doctor-over-a-whole-tree-fits-the-machine-it-runs-on)).
