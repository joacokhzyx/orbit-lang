# Do more with less.

**Orbit** is a statically typed language for APIs and microservices. It compiles
fast and needs little to run, so it stays fast under load.

Orbit tests one idea: a server can be fast without using so much energy. It is
pre-release software, and its limits are measured, not hidden.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Self-hosted](https://img.shields.io/badge/compiler-self--hosted-blueviolet)](docs/internals/SOVEREIGNTY.md)

![Orbit Banner](assets/orbit_banner.png)

---

## 5 minutes: run a service

You need a C compiler, Python 3.10+, and git. Nothing else.

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
python scripts/trust.py build --out orbit
./orbit build examples/health_service.orb -o health_service
./health_service 8080
curl http://127.0.0.1:8080/health
```

```text
{"status":"UP","version":"0.1.0","uptime_seconds":0}
```

That is a real Orbit service: one binary, live telemetry at `/metrics`, and
per-route costs at `/_ledger`. On Windows use `.\orbit.exe` and
`.\health_service.exe 8080` ([details](docs/GETTING_STARTED.md)).

## 30 minutes: learn the language

The [Language Tour](docs/GETTING_STARTED.md#a-thirty-minute-tour) walks through functions, models, routes,
SQLite reads and telemetry. Every snippet runs, and every output is verified.
Then pick a tutorial:

- [Blog API with auth](docs/tutorials/blog-api.md), with a runnable example.
- [File server and uploads](docs/tutorials/file-server.md), with scope stated.
- [Deploy a single binary](docs/tutorials/deploy-single-binary.md), on Windows
  and Linux, plus one-box clustering.
- [Troubleshooting](docs/tutorials/troubleshooting.md): ports, silent exits,
  slow first boots.

## What 0.1.0 supports, and what it does not

Compiles and serves: reads and writes, bearer auth, path parameters, multipart
uploads, and DB migrations in both directions. Forward DDL runs once per
`migrations` line and is tracked in `_orbit_migrations`;
`ORBIT_MIGRATE_DOWN=<version>` rolls one back
(`orbit migrate`, `runtime/database.c:222`, `tests/suite/migrations_down.orb`).

Not there yet: multi-host clustering, a language server, and a latency
percentile split by outcome.
The measured list with workarounds is [Known Limitations](docs/KNOWN_LIMITATIONS.md).
Twenty questions, answered plainly: [FAQ](docs/SUPPORTED.md#frequently-asked-questions).

On a host where the compiler finds an `r6` it can run, the native backend is
the default for the programs R6 accepts: it emits IR and runs R6, with no C
compiler. R6 refuses every program that declares a route, and a refusal is a
compile error, so a service build needs `--backend=c`. Where no r6 is present
the C backend is the default.

## Usage

```sh
orbit build main.orb -o main   # compile to a native executable
orbit run main.orb             # build and run (servers keep the terminal)
orbit check main.orb           # typecheck without emitting code
orbit fmt main.orb             # format (writes only on success)
orbit doctor ./examples        # read-only project checks
orbit migrate main.orb         # apply migrations without starting it
```

Full reference: [Command Reference](docs/COMMANDS.md).

## Documentation

Start at the [documentation map](docs/README.md), which lists every page by the
question it answers. The pages reached most often:

- [Getting Started](docs/GETTING_STARTED.md) · [FAQ](docs/SUPPORTED.md#frequently-asked-questions) · [Known Limitations](docs/KNOWN_LIMITATIONS.md)
- [Language Reference](docs/LANGUAGE_REFERENCE.md) · [Language Tour](docs/GETTING_STARTED.md#a-thirty-minute-tour)
- [Architecture](docs/ARCHITECTURE.md) · [Performance](docs/internals/PERF.md) · [Changelog](docs/CHANGELOG.md)
- [Platform Support](docs/SUPPORTED.md#platforms) · [Versioning](docs/SUPPORTED.md#versions-and-compatibility) · [Server Examples](examples/README.md)

## Repository structure

```text
compiler/     Self-hosted compiler written in Orbit (lexer -> parser -> sema -> IR -> C backend)
runtime/      C runtime (http, arena, admission, database, auth, ledger, energy, pulse)
std/          Orbit standard library modules
scripts/      Developer entry point (dev.py) plus the verification gates
tests/        Parity goldens and compiler test fixtures
docs/         Language reference and internal design documentation
examples/     Orbit service examples covering HTTP, auth, and database access
editors/      VS Code extension (syntax highlighting, snippets)
installer/    Windows installer source (orbit.iss)
assets/       Logo, banner, and icon artwork
.github/      CI workflows plus issue/PR templates
.orbit/       Local dev-loop scratch (cache, temp, gate work dirs; git-ignored)
```

`sqlite3.dll` at the repository root, when present, is a stray local Windows
SQLite DLL (git-ignored), not part of the repository.

## Contributing

Start with the [Contributing Guide](CONTRIBUTING.md), the
[Code of Conduct](CODE_OF_CONDUCT.md) and the [branch rules](CONTRIBUTING.md#branches).
Security reports follow [SECURITY.md](SECURITY.md).

`scripts/dev.py` (through `make`) is the entry point and owns the gate flags.
Do not pass `--cc` or `--compiler` by hand:

```sh
make dev      # gates proportionate to what the working tree touched
make check    # T0..T2 unconditionally
make all      # T0..T3, including the root of trust
```

## License

Orbit is open source under the [MIT License](LICENSE). It is pre-release
software, published with what works, what does not, and how it was measured.
