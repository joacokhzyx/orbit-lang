# Sovereign Toolchain Architecture and Independence Levels

This document describes how Orbit eliminates external compiler, assembler, and linker dependencies for its native compilation path, and defines the levels of toolchain sovereignty.

## Sovereignty Levels

To systematically measure and track toolchain independence, Orbit defines the following levels:

### Level 0: Seed (Zig + Steel Bootstrap)
*   **Definition**: The initial compiler exists as a Zig codebase. It relies on the Zig compiler to produce the initial host compiler binary. The runtime exists in C and requires a C compiler (Steel path) to build.
*   **Dependencies**: Zig toolchain, GCC/Clang, system linkers.

### Level 1: Autonomía Local (Photon Native Relocatable Objects)
*   **Definition**: The native backend (Photon Native) is capable of translating Orbit source/MIR into LIR and emitting fully compliant, relocatable object files (`.obj` for Windows COFF, `.o` for POSIX ELF64) directly, without invoking external assemblers (e.g. `ml64.exe` or `as`).
*   **Dependencies**: External linkers (`link.exe` or `ld`) to produce final executables.

### Level 2: Desacoplamiento de Toolchain (Sovereign Linker)
*   **Definition**: The toolchain includes a built-in symbol resolver and executable image builder. It performs relocations, section layout, and emits executable images (PE64/ELF64) directly.
*   **Dependencies**: No external toolchain dependencies for normal binary generation.

### Level 3: Autohospedaje Local (Self-hosted compiler)
*   **Definition**: The Orbit compiler is rewritten in Orbit. Using the Level 2 compiler, we can compile the Orbit compiler source into a native, standalone compiler executable.
*   **Dependencies**: Self-contained. The compiler is written in the language it compiles.

### Level 4: Reproducibilidad Determinista (Fixed Point)
*   **Definition**: The compiler achieves fixed-point reproducibility. If we use the compiler compiled at Stage $N$ to compile the compiler source again, the output binary at Stage $N+1$ is byte-identical to Stage $N$.
*   **Timestamps & Metadata**: Timestamps, paths, and environment settings are either omitted or normalized to ensure byte-perfect consistency.

### Level 5: Double Diversified Compilation (DDC)
*   **Definition**: The self-hosted compiler is compiled via two separate bootstrap paths:
    1.  The Native compiler path (generating binary $A$).
    2.  The C compiler reference path (Steel) + independent C compiler (generating binary $B$).
    If both binaries produce byte-identical results when compiling the compiler source again, trust is verified.

### Level 6: Verificación Diversa
*   **Definition**: Continuous verification of correct behavior by comparing Photon Native and Steel outputs under identical test suites (differential testing).
