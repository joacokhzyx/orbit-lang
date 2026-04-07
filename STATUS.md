# Orbit Binary Status

This is the single source of truth for current engineering status.

## Validation Snapshot

- Date: 2026-04-06
- Host: Windows
- Branch state: `main` synchronized with `origin/main`
- Latest core commit: `5914f10`
- `zig build`: pass
- `zig build test`: pass
- `zig build run -- build test.orb`: pass
- `zig build run -- build test_phase2.orb`: pass

## Current State

- Compiler pipeline is active end-to-end: parse, semantic analysis, IR build, C backend, native compile.
- Architecture is modularized across frontend, sema modules, IR modules, codegen modules, and runtime C modules.
- C backend fallback returns were hardened; sample non-void return warnings are resolved in current validation set.
- Sema now emits `match/non-exhaustive` diagnostics for enum/union matches without wildcard coverage.
- Orbit LSP and Orbit VS Code are treated as complementary modules and remain deferred for installer integration at release time.

## Execution Focus (Phase 2)

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
