# Orbit — Status

This document details the architectural status of the Orbit programming language compiler, sovereign standard library, native x86-64 backend, and self-hosting bootstrap pipeline.

---

## 1. Architecture & Subsystems

| Component | Status | Description |
| :--- | :--- | :--- |
| **Host Compiler (`orbit.exe`)** | **Production Ready** | Built via Zig 0.16+; supports dual backends (`--backend=c`, `--backend=native`). |
| **Native x86-64 Backend** | **In progress** | Direct machine codegen, ABI frame preservation (`rbx`, `rsi`, `rdi`, `r12`..`r15`), SSE2 float SIMD, PE64/ELF IAT dynamic linking. IRs outside the supported scope return `error.NativeBackendUnsupported`, and `--emit=lir` is not yet implemented (see `src/main.zig`). |
| **Self-Hosted Compiler (`compiler/`)** | **In progress** | Written 100% in Orbit across 19 modules (16 top-level `.orb` + 3 in `compiler/frontend/`). Includes AST parser, IR builder, C backend, and recursive module resolver (`resolver.orb`). The fixed-point bootstrap (stage1→stage2→stage3) does not yet converge: stage2→stage3 still crashes in the C-backend pass. |
| **Orbit Arena Engine** | **Production Ready** | Zero-GC epochal virtual memory allocation (`VirtualAlloc`/`mmap`) with $O(1)$ fast-path bump allocation and region recycling. |
| **Orbit Kynx Engine** | **Production Ready** | Sovereign zero-trust admission control, dynamic state transitions (`STABLE` → `SIEGE`), and CPU instruction-boundary lease verification. |
| **Orbit Superluminal** | **G1 complete** | Automatic compile-time universal evaluator (CTEVAL), purity analysis, $O(2^N) \to O(N)$ pure call memoization, and strength reduction. G1 correctness gates are closed (see `docs/SUPERLUMINAL.md`); G2+ remain roadmap. |
| **VS Code Extension** | **Production Ready** | Full syntax grammar covering 100% of Orbit keywords, types, HTTP directives, and LSP integration. |

---

## 2. Completed Milestones

### A. 5-Pillar Native x86-64 Backend
- **Pillar 1**: ABI stack frame preservation (`push_r`/`pop_r` for callee-saved registers) and operand clobbering protection.
- **Pillar 2**: Native Import Address Table (IAT) generation in PE64 (`src/backend/link/pe_image.zig`) mapping `kernel32.dll`, `ws2_32.dll` (HTTP), and `sqlite3.dll`.
- **Pillar 3**: MIR Optimizer engine (`src/backend/mir/optimizer.zig`) with Constant Folding, Strength Reduction (`x * 2` → `x << 1`), and Dead Code Elimination.
- **Pillar 4**: SSE2 double-precision floating point instructions (`movsd_rr`, `addsd_rr`, `subsd_rr`, `mulsd_rr`, `divsd_rr`).
- **Pillar 5**: Self-hosting bootstrap pipeline implemented (`orbit bootstrap`). The fixed point is not yet reached: stage2→stage3 does not converge, so `zig build test` cannot claim 100% self-hosting verification.

### B. Self-Hosting Recursive Module Resolver (`compiler/resolver.orb`)
- Implemented `resolveModuleAST` to recursively parse and merge imported modules (`import "./..."`) into a unified AST representation.
- Added path resolution (`resolveFilePath`, `getDir`) and quote stripping (`stripQuotes`).

### C. Developer Tooling & Editor Integration
- Updated VS Code extension syntax grammar (`editors/vscode/syntaxes/orbit.tmLanguage.json`) to highlight 100% of Orbit language keywords and types.
- Generated multi-resolution `orbit.ico` icon files from new SVG/PNG branding assets (`assets/orbit_logo.png`).

---

## 3. Verification

```powershell
# Execute full compiler test suite
zig build test

# Run orbit doctor diagnostic
orbit doctor

# Execute multi-stage self-hosting bootstrap
orbit bootstrap
```
