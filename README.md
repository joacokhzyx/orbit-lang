# Orbit

![Orbit banner](orbit_banner.png)

Orbit is a compiled, statically typed programming language for native services.
The production compiler is **`orbit`**. It uses the C backend, links through the
system C toolchain, and is the only supported compilation path for this release.

> **Release candidate:** `0.1.0-rc.2`. Read the [current language status](STATUS.md)
> before deploying Orbit workloads.

## Build from source

Orbit currently requires the Zig nightly version declared in `build.zig.zon`.

```sh
git clone https://github.com/orbit-lang/orbit-lang.git
cd orbit-lang
zig build -Doptimize=ReleaseFast
```

The installed compiler is `zig-out/bin/orbit` (`orbit.exe` on Windows).

## Use

```sh
orbit build hello.orb
orbit run hello.orb
orbit bootstrap --stage=3 --verify
```

`orbit build` is the standard production command. The compiler includes a
native x86-64 backend for internal development, but it is deliberately absent
from the public CLI reference: it is very early, incomplete, and may generate
incorrect programs. Do not use it for production.

## Documentation

- [Language reference](docs/LANGUAGE_REFERENCE.md)
- [Release status and platform support](STATUS.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Server examples](examples/README.md)

## Repository layout

```text
compiler/   Self-hosted Orbit compiler sources
src/        Zig bootstrap compiler and runtime
std/        Standard library
examples/   Small, production-shaped server examples
docs/       Language and architecture documentation
tests/      Compiler and bootstrap fixtures
```

## Contributing

Run `zig build test` before opening a change. The native backend is experimental;
changes to it must not alter the supported `orbit` C-backend path.

## License

Apache-2.0. See [LICENSE](LICENSE).
