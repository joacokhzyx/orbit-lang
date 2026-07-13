# Bootstrap Stages and Verification

This document details the bootstrap execution steps, input/output requirements, and validation metrics for each compilation phase.

## Requirements for Stage Promotion

1. **Stage 0 -> Stage 1**:
   * Uses host Zig and precompiled C runtime.
   * Promotes once the compiler source parses, typechecks, and produces a relocatable object or C code representing the compiler.
2. **Stage 1 -> Stage 2**:
   * Uses only the Stage 1 binary and standard library.
   * Validates correctness by compiling small test programs and reproducing identical MIR structures.
3. **Stage 2 -> Stage 3**:
   * The final step of the bootstrap loop.
   * Verification must show that `hash(Stage 2 binary) == hash(Stage 3 binary)` (or equivalent structural matches).
