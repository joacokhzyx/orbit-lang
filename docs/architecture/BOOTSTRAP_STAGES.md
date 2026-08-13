# Bootstrap Stages and Verification

This document details the self-hosting bootstrap execution steps and the fixed-point verification criterion.

## Pipeline

`orbit bootstrap` (driven by `src/main.zig`) compiles `compiler/main.orb` through three stages:

```
stage 0  orbit (host compiler, Zig)  build compiler/main.orb  ->  stage1.exe
stage 1  stage1.exe                  build compiler/main.orb  ->  stage2.exe
stage 2  stage2.exe                  build compiler/main.orb  ->  stage3.exe
```

Each stage emits C (`src/codegen/c_backend.zig`; self-hosted path via `compiler/c_backend.orb`)
and compiles it with `zig cc -I src/runtime`; each stage leaves its generated C beside it
as `stageN.exe.c`. The artifacts live under `compiler/selfhost/` and are git-ignored.

## Fixed-Point Verification

When `--max-stage 3 --verify` is used, the Zig driver reads `stage2.exe` and `stage3.exe`
and checks them **byte-for-byte** (identical size and contents). Equality proves the
compiler reached a fixed point: stage 2 and stage 3 are produced by different code paths
and encode the same compiler.

The earlier self-hosted runbook compared the generated C instead (`fc.exe stage2.exe.c
stage3.exe.c`); the authoritative gate is the byte-identical binary comparison performed
by the driver.

## Requirements for Stage Promotion

1. **Stage 0 -> Stage 1**: the host compiler must parse, typecheck, and produce a working
   stage1 binary from `compiler/main.orb`.
2. **Stage 1 -> Stage 2**: stage1 must rebuild the compiler without the host.
3. **Stage 2 -> Stage 3**: stage2 rebuilds the compiler; promotion requires
   `stage2.exe == stage3.exe` byte-for-byte.

## Current Status

As of HEAD `6bce0c4`, the pipeline does **not yet converge**: the snapshot handoff
(`HANDOFF-selfhost.md`) recorded stage2 dying with `0xC0000005` at the `zig cc` spawn and
stage3 crashing in its Pass 3, with `stage3.exe` never produced. Subsequent fixes
(`ae2f3d7`, `6a3b495`, `6bce0c4`) landed after that snapshot; the stages must be re-run
to establish the current state.
