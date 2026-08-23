# Orbit Programming Language

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Self-hosted](https://img.shields.io/badge/compiler-self--hosted-blueviolet)](docs/architecture/SOVEREIGNTY.md)

![Orbit Banner](assets/orbit_banner.png)

**Orbit** is a high-performance, statically typed systems programming language engineered for high-concurrency web services, microservices, and network APIs. 

Orbit combines an expressive single-line directive syntax with a high-performance **C Target** runtime featuring $O(1)$ lock-free thread-local arena recycling, zero-copy HTTP request parsing, and **Kynx** 1-nanosecond Bloom filter DDoS protection.

---

## Key Features

- **C Compiler**: Zero-copy HTTP parsing and single-syscall socket flushing delivering **10,000+ RPS** under extreme concurrency.
- **Secured By Kynx**: Built-in 1-nanosecond admission control and rate-limiting to protect sensitive routes under high load.
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

- **C Toolchain**: MSVC (Windows), GCC, or Clang
- **Python 3.10+** (bootstrap/verification scripts)

No Zig, no foreign toolchains: Orbit is a self-hosting compiler whose root of trust is committed C source (see [Sovereignty](docs/architecture/SOVEREIGNTY.md)).

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

## High-Stress Benchmarks

Orbit has been stress-tested across 4 core server categories against multi-threaded load clients written in **Go**, **Node.js**, **C**, and **Orbit**:

| Benchmark Category | Go Load Client | Node.js Client | C Native Client | Key Metric |
| :--- | :---: | :---: | :---: | :--- |
| **01. Raw HTTP Loop** | **10,125.0 RPS** | **5,725.0 RPS** | **5,000.0 RPS** | Zero-copy request parsing |
| **02. Auth & ORM** | **8,450.0 RPS** | **4,975.0 RPS** | **5,000.0 RPS** | SQLite entity resolution & hashing |
| **03. Page Cache Hit** | **9,375.0 RPS** | **5,475.0 RPS** | **5,000.0 RPS** | In-memory rendered template cache |
| **04. Kynx Guarded Defense** | **10,475.0 RPS** | **6,025.0 RPS** | **5,000.0 RPS** | 1-ns Bloom Filter DDoS protection |

---

## Documentation

- [Language Reference](docs/LANGUAGE_REFERENCE.md)
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Server Examples](examples/README.md)

---

## Repository Structure

```text
compiler/     Self-hosted compiler written in Orbit (lexer → parser → sema → IR → C backend)
runtime/      C runtime (http, arena_pool, kynx, orm, json)
benchmarks/   Multi-language stress testing suite (Go, Node.js, C, Orbit)
docs/         Language reference and internal design documentation
examples/     Production-shaped Orbit service examples
std/          Orbit standard library modules
tests/        Parity goldens and compiler test fixtures
```

---

## Contributing

We welcome contributions! Please review our [Contributing Guide](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) before submitting pull requests.

Run the verification gates prior to committing:

```bash
python scripts/build_selfhost.py --cc "$CC" --check-stale
python scripts/verify_seed.py --cc "$CC"
```

---

## License

Orbit is open-source software licensed under the [MIT License](LICENSE).
