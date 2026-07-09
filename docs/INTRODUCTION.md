# Introduction to Orbit

Orbit is a high-performance, compiled, closed-source programming language specifically designed for building backend services, API routing, and high-throughput server systems with compiled-in database engine support (SQLite) and security sandboxing.

## Key Features

1. **Native Compiler & Relocatable Toolchain**: Compiled directly to machine code using a C-codegen backend and LLVM-optimized Clang pipeline (`zig cc`).
2. **Built-in Database Engine**: SQLite is natively compiled into every Orbit binary. No external dependencies, drivers, or connection setup required.
3. **Advanced Error Management**: Integrated recovery blocks with the `rescue` keyword for bulletproof fallback handling.
4. **Hardened Production Runtimes**: Out-of-the-box support for symbol stripping, compiler hardening, and built-in anti-debugging checks to protect closed-source binaries.

## Getting Started

To compile your first Orbit script:

```bash
orbit build main.orb
```

This compiles `main.orb` into a standalone, hardened, stripped executable.
