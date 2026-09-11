# Getting Started

This guide builds the self-hosted Orbit compiler, verifies the fixed point, and runs a first program. You don't need much — a C compiler and Python are enough.

## 1. Prerequisites

Install:

- Git;
- Python 3.10 or newer;
- GCC, Clang, or MSVC.

Platform details and optional benchmark tools are listed in [Platform Support](SUPPORT.md).

## 2. Build Orbit

Clone the repository and enter its root:

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
```

Build a fixed-point compiler from the committed canonical C source:

### Windows PowerShell

```powershell
python scripts/build_selfhost.py --out orbit.exe
```

### Linux or macOS

```sh
python3 scripts/build_selfhost.py --out orbit
```

When automatic compiler detection is insufficient, pass `--cc gcc`, `--cc clang`, or `--cc cl` explicitly. You can also set `ORBIT_CC`; see [Platform Support](SUPPORT.md).

The commands above create a local executable in the repository root. Unless you install Orbit or add that directory to `PATH`, invoke the compiler using its local path as shown below.

## 3. Verify the Toolchain

The following commands verify convergence and the committed canonical source. Replace the compiler path with `orbit.exe` on Windows or `orbit` on Linux/macOS.

```sh
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

The parity command compares the compiler output with committed probe goldens. The behavior suite compiles and runs the executable programs under `tests/suite/`.

## 4. Write a First Program

Create `hello.orb`:

```orbit
fn main() -> int {
    return 0
}
```

Build it with the fixed-point compiler:

```sh
./orbit build hello.orb -o hello
```

On Windows, the output normally uses an `.exe` suffix:

```powershell
.\orbit.exe build hello.orb -o hello.exe
```

Run it:

```sh
./hello
```

```powershell
.\hello.exe
```

## 5. Try an HTTP Example

The repository includes service examples in [examples/README.md](../examples/README.md). Start with `health_service.orb` for a service without database setup:

```sh
./orbit build examples/health_service.orb -o health_service
./health_service
```

On Windows:

```powershell
.\orbit.exe build examples/health_service.orb -o health_service.exe
.\health_service.exe
```

Database examples require the SQLite support described in [Platform Support](SUPPORT.md).

## 6. Editor Setup

The installer registers the VS Code extension automatically. For a manual setup, see [VS Code Integration](../editors/vscode/README.md).

## Troubleshooting

### No C compiler found

Orbit can't find your C compiler. Set it explicitly, then build again:

```powershell
$env:ORBIT_CC = "clang"
python scripts/build_selfhost.py --cc clang --out orbit.exe
```

```sh
ORBIT_CC=gcc python3 scripts/build_selfhost.py --cc gcc --out orbit
```

Tip: run `clang --version` or `gcc --version` first to confirm it's on PATH. Small fix — you'll be building in seconds.

### The canonical C source is stale

The generated output doesn't match the committed canonical source. Run without `--check-stale` to inspect the converged output. Only promote a new canonical source after an intentional compiler change and after reviewing the generated diff:

```sh
python scripts/build_selfhost.py --promote
```

### A benchmark tool is missing

That's fine — the compiler doesn't need the benchmark toolchain. See [Benchmarks](../benchmarks/README.md) for the optional dependencies and the commands for that suite.
