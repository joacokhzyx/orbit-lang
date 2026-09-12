# Orbit Project Status

**Snapshot date:** 2026-09-12  
**Repository revision:** `b73d00f` (`main`)

This document is a dated project snapshot. It is intended to answer "what is true now?" without replacing the detailed engineering contract, language reference, or architecture records. Update it when a milestone changes the supported workflow or the status of a major workstream.

## Executive Summary

Orbit is a self-hosted, statically typed language and compiler for general software, with development focused on native network services for now. It compiles Orbit source to C, then uses your platform C compiler to produce the executable. You can bootstrap from committed canonical C without Zig.

The project is past the bootstrap proof-of-concept stage. Its mission is to help software do more work with fewer CPU cycles, less memory, and lower energy use. The next challenge is to make that goal measurable while tightening compiler parity, reducing unsafe type degradation in generated C, defining the public language contract, and making the runtime observable and operationally predictable.

## Current Capabilities

| Area | Current status | Evidence |
|---|---|---|
| Self-hosted compiler | Available | `compiler/*.orb`, `compiler/main.orb` |
| Zig-free bootstrap | Available | `scripts/build_selfhost.py`, `scripts/verify_seed.py` |
| Canonical C trust root | Committed and verified by the project workflow | `compiler/selfhost/stage3.exe.c` |
| C code generation | Primary backend | `compiler/c_backend.orb`, `runtime/` |
| HTTP service runtime | Available for supported service features | `runtime/http.c`, `lib/net.orb`, examples |
| Arena-based allocation | Available | `runtime/arena.c`, `runtime/arena_pool.c`, `docs/ARENA.md` |
| Database integration | Available, with schema migration work still open | `runtime/database.c`, examples, `STAB-6` |
| Behavior suite | 18 executable programs | `tests/suite/`, `tests/suite/README.md` |
| Parity and stability probes | 25-probe documented gate | `tests/parity/`, `tests/parity/README.md` |
| Editor integration | VS Code extension and syntax support | `editors/vscode/` |
| Native machine-code backend | Not available in the current tree | `SOVER-1` in `ENGINEERING.md` |
| Distributed cluster runtime | Not available as a public feature | Roadmap Phase 6 |

## Verification Workflow

The supported development workflow is C compiler plus Python. Zig is not required for build, verification, installation, or release of the self-hosted compiler.

From the repository root:

```sh
python scripts/build_selfhost.py --cc <gcc-or-clang> --check-stale
python scripts/verify_seed.py --cc <gcc-or-clang>
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

The CI contract is defined in `.github/workflows/ci-gate.yml`. It covers the self-host gate on Ubuntu and Windows, canonical seed verification, parity probes, runtime C tests, and the Orbit behavior suite.

## Active Workstreams

### Compiler Trust

**Priority:** P0  
**Status:** active

The self-hosted pipeline is the source of truth, but the engineering catalog still records an incomplete combined route, model, and database parity surface. The next compiler changes should be narrow, differential-tested, and followed by fixed-point promotion.

Key work:

- finish the remaining combined ORM and route parity cases;
- reduce unknown-type propagation and pointer/integer casts in generated C;
- establish a strict warning profile for generated C;
- keep bootstrap, parity, and behavior-suite output reproducible.

### Language Contract

**Priority:** P1  
**Status:** needs consolidation

The language reference and examples cover the main syntax, but the project still needs a single compatibility policy for types, errors, imports, arenas, routes, models, and standard-library APIs. `Result` construction, returns, and `try/catch` handling are covered by the behavior suite; binding the error payload remains open. Public behavior should be specified before adding a large feature surface. The broader language mission includes general software; the current server focus is driven by the opportunity to measure resource use in continuously running systems.

### Developer Workflow

**Priority:** P1  
**Status:** planned

The repository has build and verification scripts plus a VS Code extension. A cohesive user workflow around checking, formatting, testing, building, and running remains a roadmap item. Each command should be introduced only with a testable contract.

### Production Runtime

**Priority:** P1  
**Status:** active hardening

The runtime already covers HTTP, arenas, networking, authentication, Kynx, files, and database access. Operational contracts still need to be made explicit for graceful shutdown, timeouts, request limits, observability, cancellation, and failure behavior.

### Native Backend

**Priority:** P2  
**Status:** deferred until compiler contracts stabilize

A native backend is a long-term sovereignty and performance project. It depends on a stable IR contract and a broad differential test suite. It should remain experimental until it can match the C backend on behavior and bootstrap invariants.

### Distributed Operation

**Priority:** P3  
**Status:** deferred

Cluster behavior is intentionally not part of the current public product. Health checks, drain semantics, observability, and failure testing for a single node should mature before membership, gossip, leader coordination, and cross-node routing are implemented.

## Open Risks

| Risk | Impact | Current response |
|---|---|---|
| Generated C relies on warning suppression and broad casts | Silent miscompilation or toolchain-specific failures | Track as `STAB-3`; add strict compilation incrementally |
| Engineering catalog contains historical paths and stale status details | Contributors may choose the wrong implementation surface | Use this snapshot and `docs/README.md` as navigation; reconcile the catalog progressively |
| Behavior suite is small relative to the language surface | Regressions can escape CI | Grow the suite by contract area, starting with focused tests |
| Database schema evolution is not a complete public contract | Existing services may not upgrade safely | Track as `STAB-6`; specify migrations before implementation |
| Native backend and clustering have large dependency chains | High cost and broad failure surface | Keep them behind the compiler-trust and runtime milestones |

## Definition of a Meaningful Milestone

A milestone is meaningful when it changes one of these user-visible properties and includes evidence:

- a new supported language behavior;
- a safer or more reproducible compiler path;
- a runtime capability with failure tests;
- a documented workflow a new contributor can execute;
- a measured performance or resource improvement with a reproducible command.

Documentation-only changes may improve project clarity, but they do not close compiler or runtime milestones by themselves.

## Related Documents

- [Documentation Index](README.md)
- [Project Roadmap](ROADMAP.md)
- [Engineering Contract](../ENGINEERING.md)
- [Self-Hosting](architecture/SELF_HOSTING.md)
- [Sovereignty](architecture/SOVEREIGNTY.md)
- [Behavior Suite](../tests/suite/README.md)
- [Parity Battery](../tests/parity/README.md)
- [Versioning and Compatibility](VERSIONING.md)
- [Resource and Energy Measurement](ENERGY.md)
- [Release Artifacts](RELEASES.md)
