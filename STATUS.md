# Orbit Binary Status

This is the single source of truth for current engineering status.

## Validation Snapshot

- Date: 2026-04-06
- Host: Windows
- `zig build`: pass
- `zig build test`: pass
- `zig build run -- build test.orb`: pass
- `zig build run -- build test_phase2.orb`: pass

## Current State

- Compiler pipeline is active end-to-end: parse, semantic analysis, IR build, C backend, native compile.
- Architecture is modularized across frontend, sema modules, IR modules, codegen modules, and runtime C modules.
- Main short-term quality risk is C warning hygiene in generated output (`-Wreturn-type` warnings seen in sample builds).

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

1. Eliminate C backend warnings in generated code.
2. Add regression tests that compile representative enum/union-heavy `.orb` inputs.
3. Make VS Code extension resolve LSP path from workspace/config instead of hardcoded local path.
