# Orbit 0.1 Stable Roadmap

Orbit 0.1 must be a usable, stable, CLI-first language and compiler.
HTTP routes remain a language capability, but not a mandatory execution path.

## Product Direction

### Core principles
- Zero boilerplate
- Predictable performance
- Explicit safety and diagnostics
- CLI-first workflow
- Professional release gates

### 0.1 Scope (in)
- Stable parser + sema + IR + C backend for core language features
- CLI build/run/check workflow
- Orbit -> Orbit bootstrap Stage-2 with automated validation
- Deterministic diagnostics and regression gates

### 0.1 Scope (out)
- Full package manager
- Full LSP feature-complete experience
- Full standard library surface
- Full self-hosting codegen replacement (targeted for post-0.1)

## Definition of Done: Orbit 0.1 Stable

- [ ] `run_bootstrap_regressions.ps1` fully green in clean environment
- [ ] `zig build` fully green
- [ ] `zig build test` fully green
- [ ] CLI-first workflows validated with no mandatory HTTP dependency
- [ ] No P0/P1 open issues in parser/sema/codegen/runtime
- [ ] Error messages stable with line/column and error category
- [ ] Docs published for users and contributors
- [ ] Release notes + compatibility policy + tag process completed

## Current Status Snapshot

- [x] Internal pipeline modularized (Lexer -> Parser -> Sema -> IR -> C backend)
- [x] Stage-1 compiler flow migrated to CLI mode
- [x] Stage-2 self-hosting flow migrated to CLI mode
- [x] Legacy bootstrap `.orb` files removed from critical path
- [x] Bootstrap gate centered on CLI validations and fixtures

## Priority Matrix

### P0 (Blockers for 0.1)
- Language correctness
- Deterministic diagnostics
- Codegen stability
- Runtime correctness
- Bootstrap CLI reliability

### P1 (High value for 0.1.x)
- Performance baselines
- Better developer ergonomics
- Stronger docs and examples

### P2 (Post-0.1 evolution)
- Ecosystem expansion
- LSP depth
- Advanced tooling

## Workstream A: Language Spec Freeze (P0)

- [ ] Freeze grammar for 0.1 (operators, precedence, associativity)
- [ ] Freeze rescue semantics and fallback behavior
- [ ] Freeze enum/union/match semantics
- [ ] Freeze collection literal and method semantics
- [ ] Freeze mutability and scope rules
- [ ] Freeze function return contract semantics
- [ ] Publish canonical examples for every frozen rule
- [ ] Define 0.1.x compatibility policy (what is breaking/non-breaking)

## Workstream B: Parser and Frontend Robustness (P0)

- [ ] Ensure parser handles top-level declarations robustly at depth 0
- [ ] Improve parse recovery for malformed input (multi-error reporting)
- [ ] Harden string/comment handling (escape cases and edge cases)
- [ ] Add parser regression fixtures for all critical grammars
- [ ] Add parser performance smoke checks on medium and large files
- [ ] Ensure deterministic AST output for repeat runs
- [ ] Ensure parser path is CLI-safe and HTTP-independent

## Workstream C: Semantic Analysis and Typing (P0)

- [ ] Remove unstable `unknown` propagation in key paths
- [ ] Enforce return type correctness in all function exits
- [ ] Enforce match exhaustiveness diagnostics with stable categories
- [ ] Validate union payload typing across construction and matching
- [ ] Harden call argument type checks including nested calls
- [ ] Improve diagnostics wording and source location precision
- [ ] Add negative fixtures for semantic errors

## Workstream D: IR and C Backend Reliability (P0)

- [ ] Stabilize IR emission for mixed-type expressions
- [ ] Validate copy/move/lowering paths for rescue and match
- [ ] Ensure no invalid fallback returns are emitted in C
- [ ] Eliminate implicit C warnings on normal build paths
- [ ] Harden generated C for recursive unions and self references
- [ ] Keep `orbit_main` stub behavior deterministic when needed
- [ ] Add golden snapshots for selected generated C outputs

## Workstream E: Runtime Core (P0)

- [ ] Stabilize string conversion helpers (int/float/bool -> string)
- [ ] Stabilize string concat semantics for mixed operands
- [ ] Verify collection helpers for edge cases and null safety
- [ ] Verify memory ownership assumptions in arena-backed helpers
- [ ] Ensure deterministic behavior across Windows execution paths
- [ ] Add runtime-focused regression tests for core helpers

## Workstream F: Bootstrap Orbit -> Orbit (P0)

- [ ] Promote Stage-2 parser from summary-only to declaration extraction with names
- [ ] Validate extracted declarations through CLI fixtures
- [ ] Emit stable intermediate representation text output from self-host parser
- [ ] Add parser fixture corpus specific to self-host modules
- [ ] Validate Stage-1 and Stage-2 outputs in the same gate
- [ ] Ensure bootstrap artifacts do not require routes for execution
- [ ] Define milestone for Stage-3: sema-minimal in Orbit

## Workstream G: CLI and DX (P1)

- [ ] Standardize `build`, `run`, `check`, `dev` command behavior
- [ ] Standardize non-zero exit codes by failure category
- [ ] Add explicit quiet/verbose modes for compiler output
- [ ] Improve CLI error context and next-step hints
- [ ] Ensure path resolution is stable across CWD variations
- [ ] Add project templates for CLI-first Orbit apps

## Workstream H: Testing and Quality Gates (P0)

- [ ] Keep bootstrap regression gate green with warning-as-error discipline
- [ ] Expand CLI fixture validations for language features
- [ ] Convert remaining route-only test dependencies to CLI fixtures where viable
- [ ] Add dedicated negative test suite for parser/sema/codegen
- [ ] Add stress tests for chained imports and larger files
- [ ] Add matrix execution strategy for Windows + Linux CI

## Workstream I: Performance Baselines (P1)

- [ ] Establish baseline for compile time per canonical fixture set
- [ ] Establish baseline for generated binary size
- [ ] Establish baseline for memory behavior in compile path
- [ ] Track regressions per commit window
- [ ] Publish performance report in release notes

## Workstream J: Documentation and Release Ops (P0/P1)

- [ ] Rewrite README around CLI-first and optional HTTP capabilities
- [ ] Publish Orbit 0.1 language reference snapshot
- [ ] Publish bootstrap architecture doc (Stage-1, Stage-2, next stages)
- [ ] Publish contributor guide with local validation commands
- [ ] Publish troubleshooting guide for common compiler errors
- [ ] Prepare release checklist, changelog, and migration notes

## Sprint Plan (Execution-Oriented)

### Sprint 1 (P0)
- [ ] Spec freeze draft
- [ ] Parser regression stabilization
- [ ] Sema diagnostics consistency pass

### Sprint 2 (P0)
- [ ] IR/codegen warning elimination pass
- [ ] Runtime core hardening for string/collections
- [ ] Expanded CLI fixture suite

### Sprint 3 (P0)
- [ ] Self-host Stage-2 declaration extraction completion
- [ ] Self-host parser fixture corpus
- [ ] Bootstrap gate strengthening

### Sprint 4 (P0)
- [ ] Stage-3 sema-minimal kickoff in Orbit
- [ ] Cross-platform gate validation
- [ ] P0 bug burn-down

### Sprint 5 (P1)
- [ ] CLI UX improvements
- [ ] Output formatting and diagnostics polish
- [ ] Project template improvements

### Sprint 6 (P1)
- [ ] Performance baseline measurement and tuning
- [ ] Additional negative tests and stress tests
- [ ] Docs and examples expansion

### Sprint 7 (P0/P1)
- [ ] Release candidate hardening
- [ ] Final compatibility review
- [ ] Final gate stability burn-in

### Sprint 8 (Release)
- [ ] Tag `v0.1.0`
- [ ] Publish release notes and roadmap update
- [ ] Open 0.1.x and 0.2 tracks

## Operational Gates

### Mandatory local gate before merge
- [ ] `powershell -ExecutionPolicy Bypass -File scripts/run_bootstrap_regressions.ps1`
- [ ] `zig build`
- [ ] `zig build test`

### Mandatory release gate
- [ ] Full local gate repeated on clean workspace
- [ ] Smoke execution of CLI canonical fixtures
- [ ] No unresolved P0/P1 issues

## Risks and Mitigations

### Risk: hidden HTTP coupling reappears
- Mitigation: enforce CLI-first validations for core bootstrap paths

### Risk: parser complexity introduces regressions
- Mitigation: fixture-driven parser corpus + negative tests + snapshots

### Risk: codegen warnings regress silently
- Mitigation: warning-as-error checks in bootstrap gate

### Risk: unstable self-host momentum
- Mitigation: milestone-based Stage-2 -> Stage-3 plan with measurable outputs

## Orbit 0.1 Success Statement

Orbit 0.1 is successful when a developer can build, run, and validate real Orbit code through a reliable CLI-first compiler workflow, with deterministic diagnostics, stable runtime behavior, and a credible Orbit -> Orbit bootstrap foundation.
