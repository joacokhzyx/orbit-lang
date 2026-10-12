# Getting Started

This guide builds the Orbit compiler and runs a first program. You don't need much - a C compiler and Python are enough.

## 1. Prerequisites

Install:

- Git;
- Python 3.10 or newer;
- GCC, Clang, or MSVC.

Platform details are listed in [Platform Support](SUPPORT.md).

## 2. Build Orbit

Clone the repository and enter its root:

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
```

Build the compiler from the repository sources:

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

If you are contributing to the compiler itself, finish this guide first, then continue with the [contributor trust appendix](#appendix-contributor-trust-workflow) at the bottom.

## 3. Write a First Program

Create `hello.orb`:

```orbit
fn main() -> int {
    return 0
}
```

Build it with the compiler you just built:

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

## 4. Try an HTTP Example

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

## 5. Editor Setup

The installer registers the VS Code extension automatically. For a manual setup, see [VS Code Integration](../editors/vscode/README.md).

## Troubleshooting

Toolchain problems are covered in [Platform Support](SUPPORT.md); symptoms
you'll meet while running a service are in the
[troubleshooting tutorial](tutorials/troubleshooting.md).

## Appendix: contributor trust workflow

This section is for contributors changing the compiler itself. Newcomers stop after section 5.

Build a fixed-point compiler from the committed canonical C source, then verify convergence and the canonical. Replace the compiler path with `orbit.exe` on Windows or `orbit` on Linux/macOS, and pick a C compiler for `<gcc-or-clang>`:

```sh
python scripts/build_selfhost.py --out <path-to-orbit>
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

The parity command compares the compiler output with committed probe goldens. The behavior suite compiles and runs the executable programs under `tests/suite/`. The full model is described in [Self-Hosting](architecture/SELF_HOSTING.md) and [Sovereignty](architecture/SOVEREIGNTY.md).
