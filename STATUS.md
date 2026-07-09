# Orbit Binary Status (0.1-rc.1)

This is the single source of truth for current engineering status.

## Validation Snapshot

- Date: 2026-07-07
- Host: Windows
- Target Milestone: **Orbit 0.1-rc.1**
- `zig build test`: pass (29/29 integration & unit tests)
- `zig build run -- build test.orbit`: pass

## Current State

- Compiler pipeline is active end-to-end: parse, semantic analysis, IR build, C backend, native compile.
- Test suite has been rewritten and stabilized. 29/29 tests pass with 0 memory leaks across Parser, Sema, and IR builder.
- Parser handles syntax errors cleanly (Invalid tokens, Unclosed strings, Unexpected EOF) instead of crashing, and handles optional semicolons robustly.
- Lexer negative tests and robust array literals have been added.
- Sema correctly reports semantic diagnostics, including `match/non-exhaustive` and `DuplicateDefinition`.
- IR Builder supports `list_create` and `list_push` correctly mapping them from `array_literal` expressions.
- Runtime supports implicit string concatenations and primitives-to-string coercion via `orbit_string_concat`, `orbit_int_to_string`, `orbit_float_to_string`, and `orbit_bool_to_string` seamlessly.
- Build mode now resolves local `import "..."` chains before parsing, enabling multi-file Orbit compiler scaffolding.
- Build mode now returns non-zero status when native linking fails (`NativeCompilationFailed`), making bootstrap automation reliable.
- C backend fallback returns are now type-safe by IR return type (avoids invalid `return NULL` in non-pointer functions).

## Execution Focus (Phase 2 - Sprint 2)

- Priority 1: Type Resonance (union semantics + exhaustive match)
- Priority 2: Native collections (list/map typing + runtime interop)
- Priority 3: Result types (`Result<T, E>`) in sema and codegen
- Priority 4: Global type propagation to reduce `void*` usage in generated C

## Documentation Policy

- Canonical status document: `STATUS.md`.
- Historical progress snapshots that drift from current behavior must be removed or archived outside this root.
- Architecture and optimization docs remain technical references, not release truth.

## Workspace Hygiene Policy

- Logs and generated binaries are local artifacts and must not be tracked.
- Cleanup command:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/clean_workspace.ps1
```

- Optional full cleanup (includes build caches):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/clean_workspace.ps1 -IncludeBuildCache
```

## Next Hardening Targets

1. Add regression tests that compile representative enum/union-heavy `.orb` inputs.
2. Expand exhaustive diagnostics with missing-variant reporting and fixture assertions.
3. Add type-aware list/map operations in sema + codegen.
4. Reduce `void*` surfaces through stronger IR/type propagation.
5. Define release gate for compiler core (build, tests, benchmark baseline, docs sync).
6. Promote Orbit-in-Orbit bootstrap from Stage-0 to Stage-1 by stabilizing model/list codegen and non-void return generation.
