# Orbit Programming Language

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig Version](https://img.shields.io/badge/Zig-0.16.0%2B-orange.svg)](https://ziglang.org/)
[![Status](https://img.shields.io/badge/Status-0.1.0--rc.2-green.svg)](STATUS.md)

![Orbit Banner](assets/orbit_banner.png)

**Orbit** is a high-performance, statically typed systems programming language engineered for high-concurrency web services, microservices, and network APIs. 

Orbit combines an expressive single-line directive syntax with the **Steel C Engine**—a high-performance runtime featuring $O(1)$ lock-free thread-local arena recycling, zero-copy HTTP request parsing, and **Kynx Shield** 1-nanosecond Bloom filter DDoS protection.

---

## Key Features

- **Steel C Engine**: Zero-copy HTTP parsing and single-syscall socket flushing delivering **10,000+ RPS** under extreme concurrency.
- **Kynx Shield Protection**: Built-in 1-nanosecond admission control and rate-limiting to protect sensitive routes under high load.
- **Expressive Web Syntax**: Concise top-level single-line directives for server configuration (`port 3000`, `cors "*"`), routing (`route GET "/users" { ... }`), and ORM entities (`model User { ... }`).
- **Memory Safety & Zero GC**: Deterministic thread-local arena allocation eliminates Garbage Collector pauses without manual memory management overhead.
- **High-Performance C Code Generation**: Compiles down to optimized C99 linked directly with the platform C toolchain.

---

## Quickstart Example

Here is a full-featured Orbit HTTP service with ORM models, Kynx protection, and authenticated route groups:

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

### Prerequisites

- **Zig Compiler**: `0.15.2` or higher
- **C Toolchain**: MSVC (Windows), GCC, Clang, or `zig cc`

### Build Compiler

```bash
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit
zig build -Doptimize=ReleaseFast
```

The resulting binary will be installed at `zig-out/bin/orbit` (`orbit.exe` on Windows).

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

## High-Stress Benchmarks

Orbit has been stress-tested across 4 core server categories against multi-threaded load clients written in **Go**, **Node.js**, **C**, and **Orbit**:

| Benchmark Category | Go Load Client | Node.js Client | C Native Client | Key Metric |
| :--- | :---: | :---: | :---: | :--- |
| **01. Raw HTTP Loop** | **10,125.0 RPS** | **5,725.0 RPS** | **5,000.0 RPS** | Zero-copy request parsing |
| **02. Auth & ORM** | **8,450.0 RPS** | **4,975.0 RPS** | **5,000.0 RPS** | SQLite entity resolution & hashing |
| **03. Page Cache Hit** | **9,375.0 RPS** | **5,475.0 RPS** | **5,000.0 RPS** | In-memory rendered template cache |
| **04. Kynx Guarded Defense** | **10,475.0 RPS** | **6,025.0 RPS** | **5,000.0 RPS** | 1-ns Bloom Filter DDoS protection |

For full details, view the [Marketing & Stress Benchmark Report](benchmarks/marketing_suite/MARKETING_BENCHMARK_REPORT.md).

---

## Documentation

- [Language Reference](docs/LANGUAGE_REFERENCE.md)
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Server Examples](examples/README.md)
- [Release Status & Compatibility](STATUS.md)

---

## Repository Structure

```text
src/          Zig compiler pipeline (lexer, parser, sema, IR, C backend, diagnostics)
src/runtime/  Steel C engine (http, arena_pool, kynx, orm, json)
benchmarks/   Multi-language stress testing suite (Go, Node.js, C, Orbit)
docs/         Language reference and internal design documentation
examples/     Production-shaped Orbit service examples
std/          Orbit standard library modules
tests/        Compiler test fixtures and integration tests
```

---

## Contributing

We welcome contributions! Please review our [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before submitting pull requests.

Run the test suite prior to committing:

```bash
zig test src/tests.zig
```

---

## License

Orbit is open-source software licensed under the [MIT License](LICENSE).
