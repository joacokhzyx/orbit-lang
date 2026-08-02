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

## Existing compiler roadmap

- Sema hardening: generic parameter scope injection, impl parameter type matching, and regression tests.
- Native backend: linear-scan allocation, stack-passed ABI arguments, end-to-end object/link tests, and `.orb` pipeline regressions.
