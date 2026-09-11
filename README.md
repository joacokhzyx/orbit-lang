# Do more with less.

**Orbit** is a statically typed language for APIs and microservices. It compiles fast and needs little to run, so it stays fast even under load.

I'm building Orbit to explore a simple idea: servers and APIs shouldn't need so much energy to be fast. I'm still measuring how far it can go.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Self-hosted](https://img.shields.io/badge/compiler-self--hosted-blueviolet)](docs/architecture/SOVEREIGNTY.md)

![Orbit Banner](assets/orbit_banner.png)

Orbit combines concise service declarations with a runtime written in C. The compiler emits C99, while the runtime handles HTTP requests, reclaims memory per request with arenas, talks to the database, and applies admission control through **Kynx** when you enable it.

---

## Mission

Orbit tries to help software do more work with fewer resources. The long-term goal is to use less CPU time, less memory, and less energy to run servers and backend systems at scale.

It pursues that goal by making resource use visible and measurable: generated native code you can read, memory tied to each request, direct network handling, and benchmarks that compare throughput, latency, and resource use under the same conditions.

Orbit isn't limited to web services. Development is centered on servers and APIs for now because they run all the time and consume resources at global scale. If they need less hardware and electricity for the same service, it matters.

Energy efficiency here is an engineering target, not a slogan. I don't claim an improvement until it's measured with workload, hardware, OS, compiler, runtime config, and energy or resource data recorded. See [Resource and Energy Measurement](docs/ENERGY.md).

---

## Key Features

- **C code generation**: Orbit translates to C99 and compiles with your platform C toolchain.
- **HTTP runtime**: parses requests, dispatches routes, and writes responses without needing a separate app server.
- **Request protection**: Kynx can check admission and rate limits before a request reaches your handler.
- **Request-scoped memory**: thread-local arenas group temporary allocations by request and reclaim them together when the request ends.
- **Service-oriented syntax**: configure a service (`port 3000`, `cors "*"`), define routes (`route GET "/users" { ... }`), and describe models (`model User { ... }`) at the top level.

---

## Quickstart Example

This example combines HTTP configuration, a database model, request protection, and an authenticated route group:

```orbit
port 4000
cors "*"
database "sqlite:app.db"
kynx rate_limit 100 per_minute

model User {
    id: Int
    username: String
    email: String
}

route GET "/health" {
    return { status: "ok", uptime: 100 }
}

@auth {
    route POST "/users" {
        val user = User.create({ username: "alice", email: "alice@orbit.lang" })
        return user
    }
}
```

---

## Installation & Build from Source

For the full first run, read [Getting Started](docs/GETTING_STARTED.md). Platform details are in [Platform Support](docs/SUPPORT.md).

### Prerequisites

- **C Toolchain**: MSVC (Windows), GCC, or Clang
- **Python 3.10+** (bootstrap and verification scripts)

You don't need Zig or other toolchains. Orbit is self-hosting and bootstraps from committed C source (see [Sovereignty](docs/architecture/SOVEREIGNTY.md)).

### Build Compiler

```bash
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit
python scripts/build_selfhost.py --out orbit.exe
```

Or use the automated installer: `scripts/install.ps1` (Windows) / `scripts/install.sh` (Linux/macOS).

---

## Usage

```bash
# Build an Orbit program to native executable
orbit build main.orb

# Run in hot-reload development mode
orbit dev main.orb

# Execute compiled executable directly
orbit run main.orb
```

---

## Documentation

- [Documentation Index](docs/README.md)
- [Getting Started](docs/GETTING_STARTED.md)
- [Command Reference](docs/COMMANDS.md)
- [Platform Support](docs/SUPPORT.md)
- [Versioning and Compatibility](docs/VERSIONING.md)
- [Resource and Energy Measurement](docs/ENERGY.md)
- [Release Artifacts](docs/RELEASES.md)
- [Language Reference](docs/LANGUAGE_REFERENCE.md)
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Project Roadmap](docs/ROADMAP.md)
- [Server Examples](examples/README.md)

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
