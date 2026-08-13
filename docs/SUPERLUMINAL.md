# Superluminal

Superluminal is Orbit’s experimental optimization and program-transformation subsystem. Its purpose is not to claim arbitrary speedups: it is to make **semantics-preserving, measurable** reductions in execution work while retaining a safe fallback to ordinary code generation.

## Status

Superluminal has an implemented foundation, and its **G1 correctness gate is closed**. The compile-time evaluator (CTEVAL) interprets pure IR, and constant results are now materialized into the emitted C entry point; `src/tests.zig` (`superluminal.cteval_fib_output_consumption`) asserts the expected constants for `fib(35)` / `fib(40)`. G2+ (architectural optimizer, e-graphs, learned guidance) remain roadmap, so Superluminal is best described as **G1-complete, in implementation** rather than a finished architectural optimizer.

Aggregate performance claims are reported dynamically by the runtime loader (`boost_percent` in `src/codegen/runtime_loader.zig`) and are only attributed after a reproducible benchmark establishes what they measure.

## Current pipeline

```text
Orbit source
  → parser / semantic analysis
  → IR builder
  → CTEVAL purity + evaluation
  → constant folding / IR optimization passes
  → recursive memoization marking
  → C backend
  → generated C / executable
```

### Implemented components

- **CTEVAL** (`src/superluminal/cteval.zig`)
  - Evaluates eligible pure integer IR call graphs at compile time.
  - Supports arithmetic, comparisons, control flow, labels, blocks, copies, constants, named parameter loads, recursive calls, and memoized interpreter results.
  - Limits evaluation to 10,000,000 steps, 4,096 frames, 32 arguments, and 1,024 registers.
  - Rejects extern and runtime/I/O calls conservatively.

- **Automatic recursive memoization** (`src/superluminal/memoize.zig`)
  - Identifies pure recursive numeric functions.
  - Marks candidates with a pass-order-independent IR marker.
  - Drives static-cache wrapper emission in the C backend.

- **C backend integration** (`src/codegen/c_backend.zig`)
  - Emits static value and presence caches for eligible recursive functions.
  - Binds source-level parameters correctly to ABI parameters in memoized wrappers.

## Evidence and current limitation

For Fibonacci, emitted C contains a real static memoization cache and an executable wrapper. The CTEVAL result-materialization regression (`superluminal.cteval_fib_output_consumption`) verifies that observable consumers such as `print` receive the evaluated constants, with expected values `9227465` for `fib(35)` and `102334155` for `fib(40)`.

The G1 gate for this path is closed:
1. Result materialization in the active function-body emission path is repaired.
2. End-to-end CTEVAL regressions for observable consumers such as `print` exist in `src/tests.zig`.
3. Generated output contains the expected constants for `fib(35)` and `fib(40)` (asserted by the regression suite).
4. Runtime executions are covered by the regression harness; a recorded median methodology is tracked in the G1 benchmark work.

G2+ remain open under Roadmap.

## Roadmap

### G1 — correctness and measurement

- Finish constant-result materialization.
- Regression-test extern preservation, constant output, and recursive memoization.
- Establish reproducible timing methodology and attribution.

### G2 — architectural optimizer

- Add explicit control-flow/effect representation and SSA where beneficial.
- Introduce safe, proof-oriented rewrites and cost accounting.

### G3 — optimization search

- Use e-graphs for equality saturation over local pure regions.
- Add deterministic cost models for latency, throughput, memory, and code size.

### G4 — algorithmic transformation research

- Recognize bounded dynamic-programming and recursion patterns.
- Produce only verified alternatives with fallbacks and differential tests.

### G5 — learned guidance

- Explore learned search guidance only after deterministic correctness and cost-model baselines exist.

## Engineering principles

- No mock optimization paths.
- No performance statement without a benchmark, baseline, environment, and reproducible evidence.
- No transformation across unresolved side effects.
- Preserve a semantically equivalent fallback whenever proof is incomplete.
- Prefer correctness gates and regression tests over broad but unverified claims.
