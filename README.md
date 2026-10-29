# Do more with less.

**Orbit** is a statically typed language for APIs and microservices. It compiles fast and needs little to run, so it stays fast even under load.

Orbit explores a simple idea: servers and APIs shouldn't need so much energy to be fast. It is early-stage software, and its limits are still being measured.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Self-hosted](https://img.shields.io/badge/compiler-self--hosted-blueviolet)](docs/architecture/SOVEREIGNTY.md)

![Orbit Banner](assets/orbit_banner.png)

---

## 5 minutes: run a service

You need a C compiler, Python 3.10+, and git. Nothing else.

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
python scripts/build_selfhost.py --out orbit
./orbit build examples/health_service.orb -o health_service
./health_service 8080
curl http://127.0.0.1:8080/health
```

```text
{"status":"UP","version":"0.1.0-rc.2","uptime_seconds":0}
```

That's a real Orbit service: compiled to one binary, live
telemetry at `/metrics`, per-route costs at `/_ledger`. On
Windows use `.\orbit.exe` / `.\health_service.exe 8080`
([details](docs/GETTING_STARTED.md)).

## 30 minutes: learn the language

The [Language Tour](docs/TOUR.md) walks you through functions,
models, routes, SQLite reads, and telemetry - every snippet
runnable, every output verified. Then pick a tutorial:

- [Blog API with auth](docs/tutorials/blog-api.md) - runnable
  example + expected outputs.
- [File server + uploads](docs/tutorials/file-server.md) -
  same deal, scope stated up front.
- [Deploy a single binary](docs/tutorials/deploy-single-binary.md) -
  Windows + Linux, plus one-box clustering.
- [Troubleshooting](docs/tutorials/troubleshooting.md) -
  ports, silent exits, slow first boots.

## What 0.1.0 can't do yet

Reads and writes work, with bearer auth and path parameters.
Multipart uploads, DB migrations, and p50/p99 aren't there yet.
The full list with workarounds is public:
[Known Limitations](docs/KNOWN_LIMITATIONS.md).
Twenty hard questions, answered plainly: [FAQ](docs/FAQ.md).

## Usage

```sh
orbit build main.orb -o main   # compile to a native executable
orbit run main.orb             # build and run (servers keep the terminal)
orbit check main.orb           # typecheck without emitting code
orbit fmt main.orb             # format (writes only on success)
orbit doctor ./examples        # read-only project checks
```

Full reference: [Command Reference](docs/COMMANDS.md).

---

## Documentation

- [Language Tour](docs/TOUR.md) · [Getting Started](docs/GETTING_STARTED.md) · [FAQ](docs/FAQ.md)
- [Known Limitations](docs/KNOWN_LIMITATIONS.md) · [Changelog](docs/CHANGELOG.md).
- [Language Reference](docs/LANGUAGE_REFERENCE.md) · [Architecture](docs/ARCHITECTURE.md) · [Project Status](docs/STATUS.md) · [Roadmap](docs/ROADMAP.md).
- [Migrations guide](docs/guides/migrations.md) · [Performance notes](docs/PERF.md) · [Resource and energy measurement](docs/ENERGY.md).
- [Platform Support](docs/SUPPORT.md) · [Versioning](docs/VERSIONING.md) · [Server Examples](examples/README.md).

---

## Repository Structure

```text
compiler/     Self-hosted compiler written in Orbit (lexer → parser → sema → IR → C backend)
runtime/      C runtime (http, arena, kynx, database, auth, ledger, energy, pulse)
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

`sqlite3.dll` at the repo root, when present, is a stray local Windows SQLite DLL (git-ignored), not part of the repository.

---

## Contributing

Thanks for your interest. Please start with the [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

Run the verification gates before committing. `scripts/dev.py` (via `make`) is the entry point - do not pass `--cc`/`--compiler` by hand:

```sh
make dev      # gates proportionate to what the working tree touched
make check    # T0..T2 unconditionally
make all      # T0..T3, including the root of trust
```

---

## License

Orbit is open source under the [MIT License](LICENSE). It is early-stage software - published with what works, what doesn't, and how it was measured.
