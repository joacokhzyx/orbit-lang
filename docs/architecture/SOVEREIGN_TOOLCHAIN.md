# Sovereign Toolchain Architecture

This document describes how Orbit eliminates external compiler, assembler, and linker dependencies for its native compilation path.

## Architectural Components

1. **Direct Machine Code Emission (Photon Native)**:
   * Translates Low-level Intermediate Representation (LIR) instructions directly to target-specific machine bytes (x86-64 opcodes).
2. **Sovereign Object Emitter**:
   * Encodes section data, relocation entries, and symbol tables directly into COFF (Windows) or ELF (Linux/macOS) format without invoking `as` or `ml64.exe`.
3. **Sovereign Linker**:
   * Resolves external symbols, layouts section boundaries, patches relative displacements (relocations), and packages relocatable object files along with runtime components into raw PE/ELF executables.
