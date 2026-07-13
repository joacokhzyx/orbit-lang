# Reproducible Bootstrap Process

This document defines the requirements and commands for clean-room, deterministic builds of the Orbit compiler without network access.

## Verification Checklist

1. The stage 1 compiler is compiled using the stage 0 seed compiler:
   ```bash
   orbit build --backend=native compiler/main.orb -o stage1/orbit
   ```
2. The stage 2 compiler is compiled using the stage 1 compiler:
   ```bash
   stage1/orbit build --backend=native compiler/main.orb -o stage2/orbit
   ```
3. The stage 3 compiler is compiled using the stage 2 compiler:
   ```bash
   stage2/orbit build --backend=native compiler/main.orb -o stage3/orbit
   ```
4. Verify fixed-point equivalence:
   * Compilers generated in Stage 2 and Stage 3 must have identical canonical MIR.
   * Compilers must produce byte-identical native binaries.
