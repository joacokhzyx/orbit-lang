# Orbit Compiler — Implementation Plan

## Current State (0.1.0-rc.2)

- Parser, semantic analysis, IR builder, C backend, and native-backend foundations exist.
- G0 compiler reliability work is committed: extern calls are not folded as constants; CLI/frontend/import failures return non-zero exits; the stress suite completed 32 tests.
- G1 Superluminal work is implemented but **not yet accepted as complete**: the compiler builds and emits memoized recursive C wrappers, but the constant-result materialization path for entry-point output is still incorrect.

## Completed: Superluminal foundation

- CTEVAL safety limits: 10,000,000 interpreter steps, 4,096 recursive frames, 32 call arguments, and 1,024 interpreter registers.
- CTEVAL supports IR blocks, labels, named parameter loads, declarations, constants, copies, arithmetic, comparisons, branches, recursive calls, and memoized evaluation.
- External functions are conservatively excluded from compile-time folding.
- The memoization pass detects eligible pure recursive numeric functions and marks them independently of pass ordering.
- The C backend emits a static memo cache and correctly binds ABI parameters to source-level parameters in memoized wrappers.

## Active blocker: G1 correctness gate

The generated C for `fib.orb` contains the memoized `fib` wrapper, but `orbit_main` prints uninitialized result registers. The source calls were removed before the result was materialized in the active code-generation path.

### Required before G1 acceptance

1. Trace the active `emitFunctionBody` path and repair constant-result materialization there.
2. Add a real regression test covering CTEVAL output consumption, including `print(fib(35))` and `print(fib(40))`.
3. Rebuild and verify emitted C contains `9227465` and `102334155` at the output sites.
4. Run 10 executable samples: exact output, zero exit status, and median under 150 ms.
5. Preserve the existing `Superluminal boosted 5.2%` display until a reproducible attribution metric exists.

## Next engineering layers (not started)

1. Explicit CFG/SSA and effect analysis.
2. E-graph equality saturation for local optimization search.
3. Algorithmic idiom recognition and verified alternative implementations.
4. Partial evaluation / Futamura-style specialization experiments.
5. Learned cost-model-guided optimization search.

## Existing compiler roadmap

- Sema hardening: generic parameter scope injection, impl parameter type matching, and regression tests.
- Native backend: linear-scan allocation, stack-passed ABI arguments, end-to-end object/link tests, and `.orb` pipeline regressions.
