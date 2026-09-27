# Superluminal

Superluminal is Orbit's experimental optimization and program-transformation work. Its purpose isn't to claim speedups. It's to make measurable reductions in execution work that preserve semantics, with a safe fallback to ordinary codegen when proof is incomplete.

## Status (honest baseline)

The live baseline is three things: a pure-integer compile-time evaluator
(`compiler/cteval.orb`, entry `cteOptimize`, wired at
`compiler/pipeline.orb:282-287`), a peephole pass over
`add`/`sub`/`mul`/`div`/`neg`/`not_op` (`compiler/optimizer.orb:426-523`),
and a constant-sinking pass that shortens live ranges.

There is no memoization marker and no static-cache emission: references to
files under the old `src/` tree in earlier revisions of this document
described a source layout that no longer exists and are superseded below. No
in-scope probe asserts large constant folds (`tests/suite/fn_recursive.orb`
proves only `fact(5)`).

Aggregate performance claims are never attributed to static estimates. The
pass reports how many patterns it applied and how much span it saved
(`OptStats`); that is a count of rewrites, never a speedup.

## Current pipeline

Live order at `compiler/pipeline.orb:282-287`:

```text
Orbit source
  → parser / semantic analysis
  → IR builder
  → optimizeIRModule (peephole rewrites, then constant sinking)
  → cteOptimize, both passes gated by cteEnabled() (compiler/pipeline.orb:11-13)
  → generateC
  → generated C / executable
```

### Implemented components

- **CTEVAL** (`compiler/cteval.orb`)
  - Evaluates eligible pure integer IR call graphs at compile time.
  - Interpreter coverage: arithmetic, comparisons, jumps, labels,
    blocks, copy, `load_const`, named parameter loads
    (`compiler/cteval.orb:394-418`), recursive calls with purity
    re-check (`compiler/cteval.orb:692-710`), runtime-call rejection
    via `isRuntimeFunction` (`compiler/cteval.orb:22-32`) and `isPure`
    (`compiler/cteval.orb:54-78`). Float constants are rejected
    (`compiler/cteval.orb:435-439`).
  - Step and depth caps live at `compiler/cteval.orb:381-384` and the
    per-instruction step check at `compiler/cteval.orb:399-403`.
  - Explicitly absent: a 32-argument cap, a 1,024-register cap, and
    memoized interpreter results.
  - Both optimization passes share one kill switch: `ORBIT_NO_CTE=1`
    skips them and emits pre-pass IR, and `cteEnabled()` is the only
    gate. Their counters are reported under `--verbose`
    (`opt: N patterns, N folds, span N`) rather than dropped.

- **Peephole** (`compiler/optimizer.orb:426-523`)
  - Rewrites `add`, `sub`, `mul`, `div`, `neg` and `not_op` when the
    identity operand is a constant and the other operand resolves to an
    int literal, so a string or float operand is vetoed instead of
    folded. Both operand orders are checked for `add` and `mul`; `sub`
    and `div` check the second operand.
  - `OptStats.constant_folds` is still never incremented: the pass
    removes identities, it does not evaluate general arithmetic.
    `tests/suite/peephole_folds.orb` and
    `tests/suite/peephole_no_fold_side_effects.orb` are the gate.

- **Constant sinking** (`compiler/optimizer.orb:505-522`)
  - Moves a `load_const` definition down to its single use, over
    regions with no `label`/`jump`/`jump_if_false`. Values never
    change, so the fallback is the unmoved program itself. Gate:
    `tests/suite/arena_sink_scope.orb`.

- **Effect predicates** (`compiler/cteval.orb:34-110`)
  - `isImpureOp` (`:34-52`) vs `hasSideEffects` (`:80-110`): both answer
    `true` for every effectful opcode - `db_get`, `db_all`, `db_where`,
    `http_response`, `alloc`, `load_field`, `switch_op`, and the
    `list_*`, `map_*`, `result_*` and `union_*` families - so DCE driven
    by the predicate (`dceFunction` at `compiler/cteval.orb:980`) cannot
    delete a live database, response, or allocation operation.

- **Absent components** (no `.orb` counterpart exists)
  - No `compiler/memoize.orb`: no memoization marker or cache emission
    exists in `compiler/c_backend.orb`.
  - Handler emission calls route functions as
    `sanitizeIdentifier(func.name) + "(arena, req)"`
    (`compiler/c_backend.orb:1209`); dispatch matches `req->path` and
    `req->method` against `routePath` / `routeMethod`
    (`compiler/c_backend.orb:1231`); allocation goes through
    `orbit_arena_alloc` (`compiler/c_backend.orb:2354`) and no `free` is
    emitted at all - the request's arena epoch reclaims it.
  - `compiler/ir.orb:3-70` has flat opcodes with labels and jumps but
    no CFG, effect summary, or SSA.

## Where this work is tracked

Optimization work is not planned here. [Project Roadmap](ROADMAP.md)
owns the phases (Phase 1, Compiler Trust, is where compiler work lives) and
[ENGINEERING.md](../ENGINEERING.md) owns the per-finding record, including the
measured ship decisions and why a change was reverted. This page answers one
question only: what the compiler actually does to your program today.

Aspiration, for the record and with no plan attached: full SSA, CFG
construction, e-graphs, cost-model search, DP/recursion recognition, learned
guidance, recursive memoization with static caches. Recursive memoization
stays dead until, at minimum: a complete purity conjunction with negative
tests per clause, a key specification, a concurrency design for the worker
loop, and a generalization gate on more than one recursion shape.

## Engineering principles

- No mock optimization paths.
- No performance statement without the command that produced it, the baseline, the environment, and the spread across runs.
- No transformation across unresolved side effects.
- Preserve a semantically equivalent fallback whenever proof is incomplete.
- Prefer correctness gates and regression tests over broad but unverified claims.
