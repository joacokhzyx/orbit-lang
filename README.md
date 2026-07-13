# Orbit

Orbit is a compiled, statically typed programming language targeting native
binaries and C output. It is self-hosting: the compiler is written in Orbit
and built by a Zig bootstrap host.

The compiler supports two backends:

- **Steel** — transpiles to C, linked with the system C compiler.
- **Photon Native** — emits x86-64 machine code and links PE/ELF executables
  without any external linker.

Orbit is pre-release software. Interfaces and syntax will change.

## Building from Source

**Prerequisite:** [Zig master](https://ziglang.org/download/) (nightly builds
from ziglang.org; the version in `build.zig.zon` is the minimum tested).

```sh
git clone https://github.com/orbit-lang/orbit.git
cd orbit/orbit-binary
zig build                          # debug build
zig build -Doptimize=ReleaseFast   # optimized build
zig build test                     # run the test suite
```

The compiler binary is written to `zig-out/bin/orbit`.

## Usage

```sh
orbit build hello.orb              # compile to native binary
orbit build hello.orb --backend=native --linker=native   # zero-external-linker
orbit run   hello.orb              # compile and execute
orbit check hello.orb              # type-check only
orbit bootstrap --stage=3 --verify # rebuild the compiler and verify fixed-point
```

## Repository Layout

```
orbit-binary/
├── compiler/          Orbit compiler source (written in Orbit)
│   └── selfhost/      Self-hosting stage artifacts
├── src/               Zig bootstrap host
│   ├── main.zig       Compiler driver
│   ├── backend/       Code generation and linking
│   │   ├── link/      Native linker (COFF/PE, ELF)
│   │   └── x86_64/    x86-64 instruction encoder
│   ├── codegen/       C backend
│   ├── ir/            Intermediate representation
│   ├── parser/        Recursive-descent parser
│   ├── sema/          Type checker and scope analysis
│   ├── runtime/       C runtime (arena, http, collections)
│   └── tests.zig      Compiler regression suite
├── std/               Orbit standard library
├── tests/             Bootstrap fixtures
├── build.zig          Zig build script
└── build.zig.zon      Package manifest
```

## Compiler Pipeline

```
Source (.orb)
  Lexer
  Parser
  Sema (type checker, scope, diagnostics)
  IR (builder, optimizer)
  Codegen
    Steel  →  C source  →  cc / clang / gcc  →  binary
    Native →  COFF/ELF object  →  internal linker  →  binary
```

## Bootstrap

The Orbit compiler is self-hosting at Stage 3. `zig build` compiles the Zig
host that drives Stage 1. From Stage 1 the compiler rebuilds itself twice; the
Stage 2 and Stage 3 outputs must be byte-identical.

```sh
orbit bootstrap --stage=3 --verify
# [bootstrap] SUCCESS: Stage 2 and Stage 3 are byte-identical!
```

## Contributing

1. Run `zig build test` and confirm all tests pass.
2. Keep `zig build test` green on your branch before opening a pull request.
3. Add `///` doc comments to new `pub fn` declarations.

## License

Apache 2.0. See [LICENSE](LICENSE) for details.
