# Orbit Compiler — Implementation Plan

## Current State (0.1.0-rc.2)

- **Parser** — full: generics, traits, impl, union, exhaustive match.
- **Sema** — nearly complete: trait/impl/union analyze; generics parsed but type params not injected into scope.
- **IR builder** — handles functions, branches, loops, arithmetic, calls.
- **Native backend** — MIR -> LIR -> regalloc (stack) -> encoder -> COFF/ELF; linker and PE writer exist; end-to-end test is gated on orbit.exe binary.

## Phase 1 — Sema Hardening

### 1-A: Generic parameter scope injection
In analyzeFunction/analyzeModel iterate generic_params and define(param_name, type, false).

### 1-B: validateImpl — parameter type matching
Add per-position param_type check (with unknown escape hatch).

### 1-C: Sema tests
Tests for trait/impl, union exhaustive match, generic function type param.

## Phase 2 — Native Backend

### 2-A: Linear-scan register allocator (real)
Implement live-interval computation and physical register assignment. Spill when exhausted.

### 2-B: Stack-passed args for >4/6 params
Remove @panic in lowering.zig .arg handler; push excess args per Windows/SysV ABI.

### 2-C: End-to-end Zig unit test (no subprocess)
Build IR manually, run through Backend.lower + emitObject + linker + writer, verify bytes.

### 2-D: .orb regression tests
Add .orb files for trait/impl, union/match, generics, arithmetic through full pipeline.

## Order

Phase 1-A, 1-B, 1-C then Phase 2-C, 2-A, 2-B, 2-D.
