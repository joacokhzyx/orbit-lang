# Sprint 1 - Phase 2 Core Plan

Scope: orbit-binary only.

Complementary modules (orbit-lsp and orbit-vscode) are intentionally out of sprint scope and will be integrated via Orbit installer in a release-ready stage.

## Goal

Deliver the first production-usable slice of Phase 2 type system hardening with measurable regression protection.

## Workstreams

1. Type Resonance foundations
- Add sema checks for union match branch coverage.
- Ensure enum match coverage checks report diagnostics with exact line/column.
- Keep permissive fallback (`_`) behavior explicit.

2. Regression suite for enum/union/match
- Add representative `.orb` fixtures under `src/tests/` or dedicated regression folder.
- Include both valid and invalid programs.
- Validate diagnostic stability (error code + location).

3. Collection typing baseline
- Add sema typing for list literals and map literals.
- Type-check `.len()`, `.push()`, and `.get()` for list/map paths used in `test_phase2.orb`.
- Emit typed IR paths (avoid generic `void*` when concrete type is known).

4. Release gate definition (core)
- Build gate: `zig build`
- Test gate: `zig build test`
- E2E gate: `zig build run -- build test.orb` and `zig build run -- build test_phase2.orb`
- Documentation gate: update `STATUS.md` and `CHANGELOG.md` in the same PR.

## Definition of Done

- No regressions in current build and test gates.
- At least 5 new regression fixtures for enum/union/match behavior.
- Exhaustive match diagnostic is emitted for missing enum/union variants.
- Collection literal typing works for current phase-2 sample program.
- `STATUS.md` snapshot refreshed with current outcomes.

## Execution Order

1. Implement diagnostics for exhaustive match in sema.
2. Add regression fixtures and assertions.
3. Implement list/map typing increments.
4. Run full release gate and update status docs.
