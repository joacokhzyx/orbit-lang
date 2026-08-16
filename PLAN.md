# Orbit Compiler — Implementation Plan

## Current State (0.1.0-rc.2)

- Parser, semantic analysis, IR builder, C backend, and native-backend foundations exist.
- G0 compiler reliability work is committed: extern calls are not folded as constants; CLI/frontend/import failures return non-zero exits; the stress suite completed 32 tests.
- G1 Superluminal work is fully implemented and **accepted as complete**: constant-result materialization path for output consumption, CTEVAL evaluation, and memoization passes verified via regression tests.

## Completed: Superluminal foundation & G1 Correctness Gate

- CTEVAL safety limits: 10,000,000 interpreter steps, 4,096 recursive frames, 32 call arguments, and 1,024 interpreter registers.
- CTEVAL supports IR blocks, labels, named parameter loads, declarations, constants, copies, arithmetic, comparisons, branches, recursive calls, and memoized evaluation.
- External functions are conservatively excluded from compile-time folding.
- The memoization pass detects eligible pure recursive numeric functions and marks them independently of pass ordering.
- The C backend emits a static memo cache and correctly binds ABI parameters to source-level parameters in memoized wrappers.
- Fixed constant-result output consumption in `tryArgInline` so built-in runtime calls (e.g. `print`) correctly emit typed outputs.
- Added regression test `superluminal.cteval_fib_output_consumption` verifying output values (`9227465` and `102334155`) for compile-time evaluated recursive calls `fib(35)` and `fib(40)`.

## Next engineering layers (not started)

1. Explicit CFG/SSA and effect analysis.
2. E-graph equality saturation for local optimization search.
3. Algorithmic idiom recognition and verified alternative implementations.
4. Partial evaluation / Futamura-style specialization experiments.
5. Learned cost-model-guided optimization search.

## Completed: Sema Hardening & Generic Scope Verification

- Injected generic type parameter scope (`injectGenericParams`) and `Self` into `analyzeTrait` in `src/sema.zig`, ensuring method signatures with parametric types resolve cleanly.
- Implemented strict per-parameter type validation in `validateImpl` (`src/sema/type_checker.zig`), matching declared types between `impl` methods and `trait` contracts with `impl/param-type` diagnostic reporting.
- Removed legacy temporary debug prints from IR builder and C backend.
- Added negative and positive regression tests: `sema.impl_param_type_mismatch_diagnosed` and `sema.trait_generic_param_scope`.
- Multi-stage self-hosting fixed-point bootstrap (`stage3.exe.c` == `stage4.exe.c`) re-verified and converged with 0 errors.

## Completed: Native x86-64 Backend ABI Stack Arguments & Frame Integrity

- Implemented correct stack-passed parameter lowering in function prologues (`src/backend/x86_64/lowering.zig`), calculating accurate frame displacements based on push ordering (`16 + (num_params - 1 - param_idx) * 8`).
- Implemented caller stack tracking (`stack_args_pushed`) and automatic `RSP` cleanup restoration (`add rsp, 8 * N`) after native calls with stack-passed arguments.
- Added end-to-end native tests in `src/backend/tests.zig`:
  - `native end-to-end: function with 6 parameters passed via registers and stack` (testing 4 register args + 2 stack args).
  - `native end-to-end: 8-parameter function called in a loop does not leak stack` (testing 4 register args + 4 stack args across iterations with zero stack leakage).
- Fixed-point bootstrap verified: `stage3.exe.c` and `stage4.exe.c` remain byte-identical (SHA256 verified).

## Completed: Linear-Scan Register Allocator Hardening

- Hardened the `linear` register allocation strategy (`src/backend/lir/regalloc.zig`):
  - Isolated operand scratch registers (`R10` for op1 source/mem base, `R11` for op2/op3 sources, `RAX` for dest) preventing dual-spill clobbering in multi-operand instructions.
  - Added memory operand base register virtual-to-physical resolution for spilled base registers.
- Added unit and machine-encoding test in `src/backend/tests.zig` (`regalloc: linear scan allocates physical registers and produces valid assembly`).
- Multi-stage self-hosting fixed-point bootstrap (`stage3.exe.c` == `stage4.exe.c`) re-verified (SHA256 verified).

## Next engineering layers (not started)

1. Explicit CFG/SSA and effect analysis.
2. E-graph equality saturation for local optimization search.
3. Algorithmic idiom recognition and verified alternative implementations.
4. Partial evaluation / Futamura-style specialization experiments.
5. Learned cost-model-guided optimization search.

## Existing compiler roadmap

- Native backend: end-to-end object/link tests and `.orb` pipeline regressions.
