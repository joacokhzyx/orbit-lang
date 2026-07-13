# ⏣ Orbit Programming Language

**Orbit** is an open-source, compiled, high-performance programming language designed for backend web services and API servers.  
It generates native C code, embeds SQLite, and ships production-ready HTTP routing, authentication, and a virtual-memory epoch allocator — all with zero third-party runtime dependencies.

---

## ✨ Feature Highlights

| Feature | Description |
|---|---|
| **Native Compilation** | Transpiles to C → compiled with system `cc` / `clang` / `gcc` |
| **Epoch-based Arena** | Virtual-memory arena with epoch reclamation (`orbit/arena`) |
| **Built-in SQLite** | SQLite compiled into every server binary |
| **HTTP Router** | Zero-alloc request parser + method/path router |
| **Orbit Kynx** | Per-route computational leases (CPU/IO budget enforcement) |
| **Orbit Pulse** | High-resolution performance counters & latency histograms |
| **Orbit Terminal** | ANSI/Unicode-aware compiler UI with color-preference detection |
| **Orbit Photon** | Incremental build cache keyed by source hash |
| **Recovery-first Errors** | `rescue` fallback expressions instead of exceptions |
| **Anti-RE Hardening** | Optional debugger-detection, symbol stripping, `-O3` |

---

## 🚀 Quick Start

```bash
# Install (Linux/macOS)
curl -fsSL https://raw.githubusercontent.com/orbit-lang/orbit/main/install.sh | bash

# Install (Windows PowerShell)
irm https://raw.githubusercontent.com/orbit-lang/orbit/main/install.ps1 | iex

# Write a server
cat > hello.orb << 'EOF'
get "/" {
  response { "Hello, Orbit!" }
}
EOF

# Compile & run
orbit build hello.orb -o hello
./hello
```

---

## 🏗️ Compiler Pipeline

```
Source (.orb)
    │
    ▼
 Lexer  ──────────────  token.zig  lexer.zig
    │
    ▼
 Parser ──────────────  parser/  (decl · expr · stmt)
    │
    ▼
 Sema   ──────────────  sema/   (type_checker · scope · models)
    │
    ▼
 IR     ──────────────  ir/     (builder · optimizer)
    │
    ▼
 Codegen (C backend)   codegen/ (c_backend · expr · stmt · route · model)
    │
    ▼
 Runtime loader ──────  codegen/runtime_loader.zig
    │
    ▼
 C compiler (cc/clang)
    │
    ▼
 Native binary
```

---

## 📦 Repository Layout

```
orbit-binary/
├── src/
│   ├── main.zig              # Compiler driver (Photon, Terminal, caching)
│   ├── lexer.zig             # Tokeniser
│   ├── token.zig             # Token definitions
│   ├── ast.zig               # AST node types
│   ├── parser.zig            # Parser entry point
│   ├── sema.zig              # Semantic analysis entry point
│   ├── compiler.zig          # Compilation orchestrator
│   ├── atlas.zig             # Project config (orbit.atlas)
│   ├── jit.zig               # JIT/cache helpers
│   ├── parser/               # Recursive-descent sub-parsers
│   ├── sema/                 # Type checker, scope, diagnostics
│   ├── ir/                   # Intermediate representation
│   ├── codegen/              # C code generator
│   ├── runtime/              # C runtime library (arena, http, db…)
│   ├── terminal/             # Terminal UI capabilities
│   └── tests/                # Unit tests
├── docs/                     # User documentation
│   └── architecture/         # Deep-dive architecture docs
├── benchmarks/               # Throughput benchmarks
├── build.zig                 # Zig build system
└── build.zig.zon             # Package manifest
```

---

## 🧪 Building from Source

**Prerequisites**: [Zig ≥ 0.14](https://ziglang.org/download/)

```bash
git clone https://github.com/orbit-lang/orbit.git
cd orbit/orbit-binary
zig build                   # Debug build
zig build -Doptimize=ReleaseFast   # Release build
zig build test              # Run all tests
```

The resulting compiler binary is at `zig-out/bin/orbit`.

---

## 📖 Documentation

| Document | Description |
|---|---|
| [Introduction](docs/INTRODUCTION.md) | Architecture, features, and quickstart |
| [Syntax Guide](docs/SYNTAX_GUIDE.md) | Variables, routing, error recovery |
| [Production Deployment](docs/PRODUCTION_DEPLOYMENT.md) | Hardening, anti-RE, installers |
| [Orbit Arena](docs/architecture/ORBIT_ARENA.md) | Epoch-based virtual-memory allocator |
| [Architecture Overview](docs/ARCHITECTURE.md) | Full compiler + runtime diagram |

---

## 🤝 Contributing

1. Fork the repo and create a feature branch.
2. Run `zig build test` — all tests must pass.
3. Add `///` doc-comments to any new `pub fn`.
4. Open a pull request with a clear description.

---

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
