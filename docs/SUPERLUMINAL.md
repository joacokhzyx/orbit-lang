# Superluminal

Superluminal is Orbit's experimental optimization and program-transformation work. Its purpose isn't to claim speedups. It's to make measurable reductions in execution work that preserve semantics, with a safe fallback to ordinary codegen when proof is incomplete.

## Status (honest baseline)

The live baseline is three things: a pure-integer compile-time evaluator
(`compiler/cteval.orb`, entry `cteOptimize`, wired at
`compiler/pipeline.orb:278-282`), a three-pattern peephole pass
(`compiler/optimizer.orb:25-50`, no commutativity, no constant folding),
and a static label-count estimator (`computeBoostRawPct` at
`compiler/c_backend.orb:1252-1319`, stored on `IRModule.boostRaw`).

There is no memoization marker and no static-cache emission: references to
files under the old `src/` tree in earlier revisions of this document
described a source layout that no longer exists and are superseded below. No
in-scope probe asserts large constant folds (`tests/suite/fn_recursive.orb`
proves only `fact(5)`). The G1 gate below is **open** until the Wave 0
and Wave 1 regression tests land.

Aggregate performance claims are never attributed to static estimates.
`computeBoostRawPct` counts labels; it must never be presented as a
speedup (see Wave 0).

## Current pipeline

Live order at `compiler/pipeline.orb:276-285`:

```text
Orbit source
  → parser / semantic analysis
  → IR builder
  → computeBoostRawPct (static estimate only, never a speedup claim)
  → optimizeIRModule (three peephole patterns)
  → cteOptimize, gated by constant cteEnabled() (compiler/pipeline.orb:11-13)
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
  - Step and depth caps live at `compiler/cteval.orb:365-369`.
  - Explicitly absent: a 32-argument cap, a 1,024-register cap, and
    memoized interpreter results.
  - `cteFolds` and `optStats` are currently unused after the call at
    `compiler/pipeline.orb:278-282`; `cteEnabled()` is constant `true`.
    Wave 0 consumes the counters and generalizes the flag into a
    tested whole-pass kill switch.

- **Peephole** (`compiler/optimizer.orb:25-50`)
  - Exactly three operand2-only patterns (`x + 0`, `x - 0`, `x * 1`),
    with no commutativity and no constant folding (the
    `OptStats.constant_folds` field is never incremented).
  - Known live hazard (STAB, fixed in Wave 0): the rules check only the
    operand-2 shape and never pin operand types, while the backend
    overloads `add` on strings (`orbit_string_concat` at
    `compiler/c_backend.orb:1837-1843`) and floats. `x + 0` on a string
    operand corrupts the program today.

- **Effect predicates** (`compiler/cteval.orb:34-95`)
  - `isImpureOp` (`:34-52`) vs `hasSideEffects` (`:80-95`): the latter
    answers `false` for `db_get`, `db_all`, `db_where`,
    `http_response`, and `alloc`, so any DCE driven by it can delete
    live database, response, and allocation operations
    (`dceFunction` at `compiler/cteval.orb:914-939`). Wave 0 repairs
    this before any transform ships.

- **Absent components** (no `.orb` counterpart exists)
  - No `compiler/memoize.orb`: no memoization marker or cache emission
    exists in `compiler/c_backend.orb`.
  - Handler emission calls route functions as
    `sanitizeIdentifier(func.name) + "(arena, req)"`
    (`compiler/c_backend.orb:1204`); dispatch matches on `routeMethod`
    and `routePath` (`compiler/c_backend.orb:1242`); allocation goes
    through `orbit_arena_alloc` (`compiler/c_backend.orb:2410`) with
    `free` as a no-op (`compiler/c_backend.orb:2418`).
  - `compiler/ir.orb:3-70` has flat opcodes with labels and jumps but
    no CFG, effect summary, or SSA.

## Roadmap

### Wave 0 - prerequisites (correctness before transforms)

1. Type-pinned peephole predicates in `compiler/optimizer.orb`: every
   arithmetic rewrite queries both operand types and vetoes string and
   float operands. Gate: `tests/suite/peephole_folds.orb` type-pin cases.
2. Effect-predicate correction plus barriers: `hasSideEffects` becomes a
   superset of `isImpureOp` (adding at minimum `db_get`, `db_all`,
   `db_where`, `http_response`, `alloc`, plus classification of
   `load_field`, `switch_op`, `result_*`, `union_*`); propagation and
   DCE treat `label`, `jump`, `jump_if_false`, `call`, and `ret` as
   barriers. Gate: `tests/suite/peephole_no_fold_side_effects.orb`.
3. Reachable fallback plus honest counting: generalize constant
   `cteEnabled()` into a tested whole-pass kill switch, consume
   `cteFolds`/`optStats`, and rename or delete `computeBoostRawPct` so
   no static label count is printed as a speedup. Gate: kill-switch
   differential run plus the fixed-point gate per
   `docs/ROADMAP.md:18-24`.

### Wave 1 - int-typed verified peephole rewrites

Closed enumerated rule set on int-typed operands only, each rule with
proof comment, side-condition veto, and veto test. Gate: extended
peephole suite plus parity goldens showing only intended folds.

### Wave 2 - static GET dispatch shape only

Build-time dispatch for fully static route tables (no params, no DB,
no request reads, no decorators or limits), with a force-generic flag
for differential testing. Gate: `tests/parity/probes/sl_route_dispatch.orb`,
client-observed latency stays inside its comparison band, goldens with
only the intended diff.

Outcome (2026-09-24, measured, ship decision: NOT shipped): a
method-grouped strcmp chain was implemented behind ORBIT_FORCE_GENERIC
and measured A/B on this box (3 static routes, 2000 requests at 50
rps x4 conns, 2 s warmup, 3 rounds each): specialized p50 median
0.140 ms vs generic 0.141 ms (0.7%, inside any compare band), with a
byte-identical differential across /, /health, /metrics, /notes/new,
/notes/42, 404s, and trailing slashes. Dispatch shape is not the
bottleneck (hash plus strcmp costs ~0.1% of a request); the emitter
was reverted rather than landing an untested-by-CI path for zero
gain. `tests/parity/probes/sl_route_dispatch.orb` stays as
precedence and collision coverage on the generic path. Future
dispatch-adjacent work belongs to the accept/parse/send paths, each
with its own measurement first.

### Wave 3 - pure-temporary motion only

Shorten live ranges of pure ALU/`copy`/`load_const` temporaries under a
conservative barrier rule; no motion of `alloc`, strings, responses,
collections, or calls across branches. Gate:
`tests/suite/arena_sink_scope.orb` plus a differential all-branch
runner with byte-identical bodies.

### Aspiration (no `.orb` counterpart; not in this plan)

Full SSA, CFG construction, e-graphs, cost-model search, DP/recursion
recognition, learned guidance, recursive memoization with static
caches. Recursive memoization stays dead until, at minimum: a complete
purity conjunction with negative tests per clause, a key specification,
a concurrency design for the worker loop, and a generalization gate on
more than one recursion shape. `docs/ROADMAP.md` defines Phases 0-6
and never mentions G-phases; nothing here overrides that.

## Engineering principles

- No mock optimization paths.
- No performance statement without the command that produced it, the baseline, the environment, and the spread across runs.
- No transformation across unresolved side effects.
- Preserve a semantically equivalent fallback whenever proof is incomplete.
- Prefer correctness gates and regression tests over broad but unverified claims.
