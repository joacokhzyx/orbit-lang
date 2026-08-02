# Superluminal

Superluminal is Orbit’s experimental optimization and program-transformation subsystem. Its purpose is not to claim arbitrary speedups: it is to make **semantics-preserving, measurable** reductions in execution work while retaining a safe fallback to ordinary code generation.

## Status

Superluminal has an implemented foundation, but it is not yet a finished architectural optimizer. The recursive memoization wrapper is emitted successfully; the compile-time evaluator can interpret relevant pure IR; however, the end-to-end CTEVAL result-materialization path is currently blocked in the active entry-point emission route. Therefore no aggregate performance claim is attributed to this work yet.

`Superluminal boosted 5.2%` remains unchanged until a reproducible benchmark establishes what it measures.

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

For Fibonacci, emitted C contains a real static memoization cache and an executable wrapper. However, the entry-point C still prints result registers before their CTEVAL replacements are materialized. This is a compiler correctness issue, not a benchmark success.

Until the following gate passes, Superluminal must be described as **in implementation** rather than complete:

1. Repair result materialization in the active function-body emission path.
2. Add end-to-end CTEVAL regressions for observable consumers such as `print`.
3. Verify generated output contains the expected constants for `fib(35)` and `fib(40)`.
4. Verify 10 runtime executions for exact output, successful exit status, and a recorded median.

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
