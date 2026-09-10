# Platform Support

This page describes the supported development paths for the current self-hosted Orbit compiler. It distinguishes required tools from optional tools used by benchmarks or historical cross-checks.

## Support Matrix

| Platform | C compiler | Python | Compiler build | Runtime target |
|---|---|---|---|---|
| Windows x86-64 | Clang, MSVC, or GCC | Python 3.10+ | Supported | Supported |
| Linux x86-64 | GCC or Clang | Python 3.10+ | Supported | Supported |
| macOS | Clang | Python 3.10+ | Supported by the POSIX scripts | Supported by the POSIX scripts |

The primary compiler workflow does not require Zig. Zig is optional and is used by the benchmark harness and by the deprecated legacy seed lineage described in [Sovereignty](architecture/SOVEREIGNTY.md).

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
| Zig master | `benchmarks/` build harness and Zig C compiler commands |
| Go | Go benchmark implementations and `hey` installation |
| Rust and Cargo | Rust benchmark implementations |
| Node.js 18+ | Node benchmark implementations |
| `hey` | HTTP load generation |
| `uvicorn` | Python HTTP benchmark implementation |
| VS Code | Editor extension and syntax support |

Missing optional tools cause individual benchmark languages to be skipped where the harness supports graceful skipping. They are not required to build Orbit itself.

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

A platform is supported when its documented compiler path passes the self-host, fixed-point, parity, and behavior-suite gates in CI or in an equivalent local environment. Benchmark compatibility is separate from compiler support. Performance numbers are not portable guarantees; they must include the hardware, operating system, compiler, workload, and measurement procedure.
