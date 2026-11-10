<p align="center">
  <img src="assets/orbit_banner.png" alt="Orbit" width="720">
</p>

# Orbit

**A compiled language for services that know what they spend.**

Orbit is a statically typed language for APIs and microservices. Every request gets its own memory arena, its own compute budget and its own line in a cost ledger. The compiler is written in Orbit and rebuilds itself from a single C file.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Self-hosted](https://img.shields.io/badge/compiler-self--hosted-blueviolet)](docs/internals/SOVEREIGNTY.md)
[![Status](https://img.shields.io/badge/status-0.1.0%20pre--release-orange)](docs/SUPPORTED.md#what-is-not-supported-yet)

## A service in one file

```orbit
model Note {
    id: string
    title: string
    body: string
    author_id: string
    created_at: string
    is_private: bool
}

route GET "/posts/search" {
    val author = req.query("author")
    if (author == "") {
        return ok 200 Note.all()
    }
    return ok 200 Note.where("author_id = ?", author)
}

route GET "/health" limit 20 / s burst 20 {
    return ok 200 """{"status":"UP"}"""
}
```

Build it and you get one binary. Each request runs in a memory arena that is reset when the request ends. Clients that go over their rate receive `429 Too Many Requests` with a `Retry-After` header. A table at `/_ledger`, reachable from the local machine only, shows what each route costs: requests, mean latency and database share.

## Why Orbit exists

A server can be fast without burning so much energy. Orbit is a bet on that idea.

In most stacks, admission control, memory limits and per-route cost accounting are libraries and habits. Orbit puts them in the language, so every service has them from the first line and every service can be measured the same way.

It is a bet, not a result. No energy saving is claimed until it has been measured with the hardware, workload and method written down ([`docs/internals/ENERGY.md`](docs/internals/ENERGY.md)). What the project does publish is what works, what does not, and how each number was taken.

## Where Orbit is going

- **Native builds for services.** [R6](https://github.com/joacokhzyx/orbit-r6), the native backend, already builds the Orbit compiler without a C compiler. Next is making it accept routes, so a service builds with no C toolchain at all.
- **Budgets written in the source.** Today the compute budget of a request follows the load on the server. The goal is to let a route declare its own limits for time, memory and database work.
- **Measured against Go and Rust.** Same machine, same workload, same method: CPU time per request, memory, and tail latency under overload. Published whether Orbit wins or loses.
- **Clusters and tooling.** Multi-host clustering is the largest gap today. The language server exists and publishes diagnostics; completion and navigation do not.

## Try it in five minutes

You need a C compiler, Python 3.10 or newer, and git.

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
python scripts/build_selfhost.py --out orbit
./orbit build examples/health_service.orb -o health_service
./health_service 8080
curl http://127.0.0.1:8080/health
```

```text
{"status":"UP","version":"0.1.0","uptime_seconds":0}
```

On Windows use `.\orbit.exe` and `.\health_service.exe 8080`. Details are in [Getting Started](docs/GETTING_STARTED.md).

## Learn the language

The [Language Tour](docs/GETTING_STARTED.md#a-thirty-minute-tour) takes about thirty minutes and covers functions, models, routes, SQLite reads and telemetry. Every snippet runs and every output was checked. After it, pick a tutorial:

- [Blog API with auth](docs/tutorials/blog-api.md)
- [File server and uploads](docs/tutorials/file-server.md)
- [Deploy a single binary](docs/tutorials/deploy-single-binary.md), on Windows and Linux, with one-box clustering
- [Troubleshooting](docs/tutorials/troubleshooting.md)

## What works today, and what does not

**Works:** reads and writes, bearer auth, path parameters, multipart uploads, and database migrations in both directions. Forward DDL runs once per `migrations` line and is tracked in `_orbit_migrations`. `ORBIT_MIGRATE_DOWN=<version>` rolls one back.

**Not yet:** multi-host clustering, completion and navigation in the language server, and a latency percentile split by outcome. There is no `async`: it parses and is refused, because nothing runs behind it.

**Native backend on Windows x64:** it is the default for the programs R6 accepts, and it needs no C compiler. R6 refuses every program that declares a route, so a service build needs `--backend=c`. On other platforms the C backend is the default.

Orbit is pre-1.0. Minor releases may include documented breaking changes, so pin your compiler version. The full list of limits, each with a workaround, is in [Known Limitations](docs/SUPPORTED.md#what-is-not-supported-yet). Twenty plain questions are answered in the [FAQ](docs/SUPPORTED.md#frequently-asked-questions).

## Commands

```sh
orbit build main.orb -o main   # compile to a native executable
orbit run main.orb             # build and run (servers keep the terminal)
orbit check main.orb           # typecheck without emitting code
orbit fmt main.orb             # format (writes only on success)
orbit doctor ./examples        # read-only project checks
orbit migrate main.orb         # apply migrations without starting the service
```

See the [Command Reference](docs/COMMANDS.md).

## How Orbit is built

One maintainer builds Orbit, working with AI coding agents under written rules ([`AGENTS.md`](AGENTS.md)). The rules keep the work checkable: the compiler must rebuild itself byte for byte, the behavior suite and the negative suite must pass, and the writing rules require every claim in the documentation to carry a command or a number.

The trusted root is C source you can read, not a binary. See [Compiler Sovereignty](docs/internals/SOVEREIGNTY.md).

## Documentation

The [documentation map](docs/README.md) lists every page by the question it answers. The ones people open most:

- [Getting Started](docs/GETTING_STARTED.md), [FAQ](docs/SUPPORTED.md#frequently-asked-questions), [Known Limitations](docs/SUPPORTED.md#what-is-not-supported-yet)
- [Language Reference](docs/LANGUAGE_REFERENCE.md), [Language Tour](docs/GETTING_STARTED.md#a-thirty-minute-tour)
- [Architecture](docs/ARCHITECTURE.md), [Performance](docs/internals/PERF.md), [Changelog](docs/CHANGELOG.md)
- [Platform Support](docs/SUPPORTED.md#platforms), [Versioning](docs/SUPPORTED.md#versions-and-compatibility), [Server Examples](examples/README.md)

## Repository layout

```text
compiler/     The compiler, written in Orbit: lexer, parser, type checker, IR, C backend
runtime/      The C runtime: http, arena, kynx, database, auth, ledger, energy, pulse
std/          Standard library modules
scripts/      Developer entry point (dev.py) and the verification gates
tests/        Parity goldens and compiler test fixtures
docs/         Language reference and design documents
examples/     Services covering HTTP, auth and database access
editors/      VS Code extension (syntax highlighting, snippets)
installer/    Windows installer source
assets/       Logo, banner and icon
.github/      CI workflows and issue and PR templates
```

## Contributing

Start with the [Contributing Guide](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md) and the [branch rules](CONTRIBUTING.md#branches). Report security issues as described in [SECURITY.md](SECURITY.md).

`scripts/dev.py`, through `make`, is the entry point and owns the gate flags. Do not pass `--cc` or `--compiler` by hand.

```sh
make dev      # gates matched to what the working tree touched
make check    # tiers T0 to T2, always
make all      # tiers T0 to T3, including the root of trust
```

## License

MIT. See [LICENSE](LICENSE).