# Bootstrap Stages and Verification

This document details the self-hosting bootstrap execution steps and the fixed-point verification criterion.

## Pipeline

The bootstrap builds `compiler/main.orb` through successive stages; each stage is
built by the previous one and compiles the same source again. In the hand-run flow
each stage leaves its generated C beside it as `stageN.exe.c`:

```
stage 0  orbit (host compiler, Zig)  build compiler/main.orb  ->  stage1.exe
stage 1  stage1.exe                  build compiler/main.orb  ->  stage2.exe
stage 2  stage2.exe                  build compiler/main.orb  ->  stage3.exe
stage 3  stage3.exe                  build compiler/main.orb  ->  stage4.exe
```

Each stage emits C (`src/codegen/c_backend.zig`; self-hosted path via `compiler/c_backend.orb`)
and compiles it with `zig cc -I src/runtime`; each stage leaves its generated C beside it
as `stageN.exe.c`. The artifacts live under `compiler/selfhost/` and are git-ignored.

## Fixed-Point Verification

A fixed point is reached when a stage built by the previous one produces the same
compiler as the next stage. In the hand-run flow this is checked by comparing the
generated C byte-for-byte: `stage3.exe.c` must equal `stage4.exe.c` (both encode the
same compiler, produced by stage2 and stage3 respectively).

When `orbit bootstrap --max-stage 3 --verify` is used, the Zig driver compares
`stage2.exe` and `stage3.exe` byte-for-byte (identical size and contents). Equality
proves the compiler reached a fixed point.

## Requirements for Stage Promotion

1. **Stage 0 -> Stage 1**: the host compiler must parse, typecheck, and produce a working
   stage1 binary from `compiler/main.orb`.
2. **Stage 1 -> Stage 2**: stage1 must rebuild the compiler without the host.
3. **Stage 2 -> Stage 3**: stage2 rebuilds the compiler; promotion requires
   `stage2.exe == stage3.exe` byte-for-byte (or equivalently `stage3.exe.c == stage4.exe.c`
   in the hand-run flow).

## Current Status

The bootstrap **converges**: `stage1 -> stage2 -> stage3 -> stage4` all succeed, and
`stage3.exe.c` is byte-identical to `stage4.exe.c`. This was reached after fixing the
seed's local-variable type inference (unknown-typed values such as list elements are now
typed `uintptr_t` so pointers are not truncated through the 32-bit `orbit_int`), which
was crashing `resolveModuleAST` with `0xC0000005`. See `HANDOFF-selfhost.md` for the full
history and the runbook.
