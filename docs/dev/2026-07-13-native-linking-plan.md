# Orbit Native Linking Plan

- **Date**: 2026-07-13
- **Author**: Antigravity

This plan outlines the design, architecture, and step-by-step phases to transition the Orbit compiler from using external linkers to direct native relocatable object emission and linking.

## 1. Objectives
- Implement relocatable object writers (COFF `.obj` for Windows, ELF `.o` for Linux) directly from Photon Native.
- Implement an archive reader for static libraries (`ar`/`.lib`) to extract symbols.
- Implement a neutral link-pivot model representing sections, symbols, and relocations.
- Implement a linker core to resolve symbols, layout sections, apply relocations, and write final images (PE64 for Windows, ELF64 for Linux) with zero external linker invocations.
- Self-host the toolchain to reachStage 2 == Stage 3 byte-identical under `--linker=native`.

## 2. File and Directory Structure
All linking logic goes under `src/backend/link/`:
- `src/backend/link/mod.zig`: Public API for object writing and linking.
- `src/backend/link/object.zig`: Neutral object model (Section, Symbol, Reloc).
- `src/backend/link/coff_writer.zig`: Emit relocatable COFF `.obj`.
- `src/backend/link/elf_writer.zig`: Emit relocatable ELF `.o`.
- `src/backend/link/coff_reader.zig`: Parse COFF `.obj`.
- `src/backend/link/elf_reader.zig`: Parse ELF `.o`.
- `src/backend/link/archive.zig`: Archive (`ar`/`.lib`) parser.
- `src/backend/link/linker.zig`: Symbol resolution, section layout, relocation.
- `src/backend/link/pe_image.zig`: Emit PE64 executable.
- `src/backend/link/elf_image.zig`: Emit ELF64 executable.
- `src/backend/link/reloc.zig`: Relocation type definitions and mathematical application.
- `src/backend/link/layout.zig`: Section alignment, address calculations.

## 3. Risks & Mitigations
- **Complexity of COFF/PE relocations and import directories**: Windows PE loading requires specific layout structure for `.pdata` and `.idata` (import directory).
  - *Mitigation*: Study the structure of Windows PE, and build test suites incrementally.
- **Relocation math overflows**: Unaligned addresses, or jumping too far (32-bit offset limits).
  - *Mitigation*: Implement strict bounds checks in `reloc.zig` and throw explicit linker errors instead of overflowing silently.
- **Breaking bootstrap fixed-point**:
  - *Mitigation*: Ensure `--linker=native` is optional/configured via CLI, preserving `--linker=system` as the default during testing, and implement rigorous verification before switching.
