# Orbit — 0.1.0-rc.2

This document details the current architectural status of the Orbit language compiler, sovereign standard library, cross-platform packaging, and self-hosting bootstrap pipeline.

---

## 1. Supported Compilation Pipeline & Architecture

| Component | Status | Notes |
| --- | --- | --- |
| **Host Compiler (`orbit.exe`)** | **Supported** | Built via Zig 0.14+; default C backend target. |
| **Self-Hosted Compiler Stage 1 (`stage1.exe`)** | **Supported & Verified** | Built directly by host compiler from `compiler/main.orb` (270 ms compile time, 0 errors, 0 warnings). Passed full end-to-end AST parsing, TIR lower, IR builder, and C codegen. |
| **Self-Hosted Compiler Stage 2 (`stage2.exe`)** | **In Verification** | Built by Stage 1 compiler (`stage1.exe compiler/main.orb -o stage2.exe`). |
| **Fixed-Point Verification (`stage3.exe`)** | **In Progress** | Ensures 100% binary parity across self-hosted generations (`orbit bootstrap`). |
| **C Backend & Target Toolchain** | **Supported** | Cross-platform C code generation using `zig cc` as driver with `-w -Wno-error=incompatible-pointer-types`. |
| **Target OS & Platforms** | **Windows / Linux / macOS** | Windows x86-64 (PE/COFF), Linux x86-64 (ELF), macOS (Mach-O). |

---

## 2. Recent Major Engineering Achievements & Refactors

### A. Fixed-Point Self-Hosting (`compiler/`)
1. **Linker Entry Point Standardization**:
   - Fixed `WinMain` undefined symbol linker errors on Windows by generating `void orbit_main(void);` forward declarations and an `int main(int argc, char** argv)` C wrapper.
2. **Tagged Union Enum Value Type Mapping**:
   - Resolved `load of misaligned address 0x3` panics.
   - Updated `src/codegen/c_backend.zig` and `compiler/c_backend.orb` to ensure enum types (such as `TokType`) are emitted as scalar integer values (`orbit_int` / `TokType`) and prevented erroneous `(void*)` pointer casting of enum constant tags (e.g. `TokType_TAG_Identifier`).
3. **C Runtime Result Unwrapping**:
   - Corrected `OrbitResult` struct unwrapping for collection operations (`list_get`, `list_create`, `list_pop`, `list_push`, `list_set`, `list_len`).
4. **Parser Infinite-Loop Guard**:
   - Updated `parseProgram` in `compiler/parser.orb` with an explicit token advancement check to prevent infinite loops when parsing unconsumed tokens.

### B. SQLite Packaging & Vendor Bloat Cleanup
1. **Removed 11 MB C Amalgamation**:
   - Deleted `src/lib/sqlite/` directory containing massive 230,000+ line C amalgamation files (`sqlite3.c` 9.19 MB, `shell.c` 1.04 MB, `sqlite3.h`).
2. **Native Cross-Platform Linkage**:
   - Replaced heavy per-build C amalgamation compilation with clean, cross-platform `-lsqlite3` dynamic/system linking when `has_db` is enabled (`-DORBIT_WITH_DB`).

### C. Sovereign Standard Library Expansion (`std/sys/`)
Added high-performance sovereign Orbit modules using **PascalCase initial capital** naming:
- `std/sys/bytes/Buffer.orb`: Binary byte packing (`writeU16LE`, `writeU32LE`), slice manipulation, and capacity management.
- `std/sys/term/Color.orb`: ANSI TrueColor 24-bit RGB and 8-bit styling (`wrapBold`, `wrapDim`, `wrapRgbForeground`, `wrapRgbBackground`).
- `std/sys/io/FileStream.orb`: Buffered file streaming reader/writer primitives.
- `std/sys/proc/Env.orb`: Operating system detection and environment variable accessors.

---

## 3. Early or Unsupported Features

| Area | Status | Notes |
| --- | --- | --- |
| Native x86-64 Machine Codegen | **Early / Experimental** | Steel C-backend is the primary production target. |
| Direct Internal Linker | **Experimental** | System toolchain (`zig cc` / `lld-link`) is used for production. |
| Non-x86-64 Architecture Targets | **Planned** | ARM64 support is scheduled for post-1.0 roadmap. |

---

## 4. Verification & Bootstrap Protocol

To verify full self-hosting fixed-point parity:
```powershell
# Rebuild host compiler
zig build

# Run self-hosted bootstrap pipeline (Stage 1 -> Stage 2 -> Stage 3)
.\zig-out\bin\orbit.exe bootstrap
```

Kynx runtime protection remains active by default (`KYNX_DB_QUERY_CHECK`).
