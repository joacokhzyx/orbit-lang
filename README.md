# Do more with less.

**Orbit** is a statically typed language for APIs and microservices. It compiles fast and needs little to run, so it stays fast even under load.

I'm building Orbit to explore a simple idea: servers and APIs shouldn't need so much energy to be fast. I'm still measuring how far it can go.

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
models, routes, SQLite reads, and telemetry — every snippet
runnable, every output verified. Then pick a tutorial:

- [Blog API with auth](docs/tutorials/blog-api.md) — runnable
  example + expected outputs.
- [File server + uploads](docs/tutorials/file-server.md) —
  same deal, honest scope.
- [Deploy a single binary](docs/tutorials/deploy-single-binary.md) —
  Windows + Linux, plus one-box clustering.
- [Troubleshooting](docs/tutorials/troubleshooting.md) —
  ports, silent exits, slow first boots.

## What 0.1.0 can't do yet

Reads work; writes don't. Bearer auth, path parameters, and
multipart uploads aren't there yet. The full list with
workarounds is public: [Known Limitations](docs/KNOWN_LIMITATIONS.md).
Twenty hard questions, answered plainly: [FAQ](docs/FAQ.md).

## Usage

```sh
orbit build main.orb -o main   # compile to a native executable
orbit run main.orb             # build and run (shares your terminal)
orbit check main.orb           # typecheck without emitting code
orbit fmt main.orb             # format (writes only on success)
orbit doctor ./examples        # read-only project checks
```

Full reference: [Command Reference](docs/COMMANDS.md).

---

## Documentation

- [Language Tour](docs/TOUR.md) · [Getting Started](docs/GETTING_STARTED.md) · [FAQ](docs/FAQ.md)
- [Known Limitations](docs/KNOWN_LIMITATIONS.md) · [Changelog](docs/CHANGELOG.md) · [0.1.0 Release Notes](docs/RELEASE_NOTES_0_1_0.md)
- [Language Reference](docs/LANGUAGE_REFERENCE.md) · [Architecture](docs/ARCHITECTURE.md) · [Project Status](docs/STATUS.md) · [Roadmap](docs/ROADMAP.md)
- [Migrations guide](docs/guides/migrations.md) · [Benchmark methodology](docs/guides/benchmark-methodology.md)
- [Platform Support](docs/SUPPORT.md) · [Versioning](docs/VERSIONING.md) · [Energy Measurement](docs/ENERGY.md) · [Server Examples](examples/README.md)

---

## Repository Structure

```text
compiler/     Self-hosted compiler written in Orbit (lexer → parser → sema → IR → C backend)
runtime/      C runtime (http, arena_pool, kynx, orm, json)
benchmarks/   Multi-language stress testing suite (Go, Node.js, C, Orbit)
docs/         Language reference and internal design documentation
examples/     Orbit service examples covering HTTP, auth, and database access
std/          Orbit standard library modules
tests/        Parity goldens and compiler test fixtures
```

---

## Contributing

Thanks for your interest — I read everything. Please start with the [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

Run the verification gates before committing:

```bash
python scripts/build_selfhost.py --cc "$CC" --check-stale
python scripts/verify_seed.py --cc "$CC"
```

---

## License

Orbit is open source under the [MIT License](LICENSE). It's early research — I publish what works, what doesn't, and how I measured it.
