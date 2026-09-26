# Platform Support

This page covers the supported paths for the current self-hosted compiler. It separates what you need from what is optional.

## Support Matrix

| Platform | C compiler | Python | Compiler build | Runtime target |
|---|---|---|---|---|
| Windows x86-64 | Clang, MSVC, or GCC | Python 3.10+ | Supported | Supported |
| Linux x86-64 | GCC or Clang | Python 3.10+ | Supported | Supported |
| macOS | Clang | Python 3.10+ | Supported by the POSIX scripts | Supported by the POSIX scripts |

The primary compiler workflow needs nothing but a C compiler and a stock `python3`.

## Required Tools

- A C compiler available on `PATH`.
- Python 3.10 or newer.
- Git when building from a checkout.

Compiler selection follows this order in the self-hosted workflow:

```text
ORBIT_CC -> CC -> gcc -> clang -> cc
```

Set `ORBIT_CC` when the compiler is not discoverable or when a specific compiler must be tested.

### Windows PowerShell

```powershell
$env:ORBIT_CC = "clang"
python scripts/build_selfhost.py --cc $env:ORBIT_CC --out orbit.exe
```

### Linux or macOS

```sh
export ORBIT_CC=clang
python3 scripts/build_selfhost.py --cc "$ORBIT_CC" --out orbit
```

## Optional Tools

| Tool | Used for |
|---|---|
| VS Code | Editor extension and syntax support |
| `curl` | Readiness polling before a live gate, and manual request checks |
| `python3` (standard library only) | Every gate script; no third-party packages are needed |

None of these are required to build, verify, install or release Orbit. `scripts/night_load.py` and `scripts/measure_selfhost.py` are stdlib-only on purpose, so a measurement never depends on a package install.

## Database Notes

SQLite-backed programs require the runtime database support and the appropriate SQLite artifact:

- Linux and macOS use the system SQLite development library.
- Windows uses the bundled files under `runtime/vendor/win-x64/`.

A project that does not use database features can use the compiler without SQLite development support.

## Installation Scripts

From the repository root:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

```sh
# Linux or macOS
bash scripts/install.sh
```

The installers prefer a released fixed-point binary when one is present. Otherwise they build the compiler from the committed canonical C source, install it under `~/.orbit/bin` or `%USERPROFILE%\\.orbit\\bin`, update the user PATH, and register the VS Code extension.

## Support Policy

A platform is supported when its documented compiler path passes the self-host, fixed-point, parity, and behavior-suite gates in CI or in an equivalent local environment. Performance numbers are not portable guarantees; they must carry the hardware, operating system, compiler, workload, and measurement procedure.
