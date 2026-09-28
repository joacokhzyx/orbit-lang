# Orbit Project Status

**Snapshot date:** 2026-09-19  
**Repository revision:** `25cfe6c` (`main`)

This document is a dated project snapshot. It is intended to answer "what is true now?" without replacing the detailed engineering contract, language reference, or architecture records. Update it when a milestone changes the supported workflow or the status of a major workstream.

## Executive Summary

Orbit is a self-hosted, statically typed language and compiler for general software, with development focused on native network services for now. It compiles Orbit source to C, then uses your platform C compiler to produce the executable. You can bootstrap from the committed canonical C with any C compiler.

The project is past the bootstrap proof-of-concept stage. Its mission is to help software do more work with fewer CPU cycles, less memory, and lower energy use. The next challenge is to make that goal measurable while tightening compiler parity, reducing unsafe type degradation in generated C, defining the public language contract, and making the runtime observable and operationally predictable.

## Current Capabilities

| Area | Current status | Evidence |
|---|---|---|
| Self-hosted compiler | Available | `compiler/*.orb`, `compiler/main.orb` |
| Bootstrap from committed C | Available | `scripts/build_selfhost.py`, `scripts/verify_seed.py` |
| Canonical C trust root | Committed and verified by the project workflow | `compiler/selfhost/stage3.exe.c` |
| C code generation | Primary backend | `compiler/c_backend.orb`, `runtime/` |
| HTTP service runtime | Available for supported service features | `runtime/http.c`, `compiler/route_runtime.orb`, examples |
| Arena-based allocation | Available | `runtime/arena.c`, `runtime/arena_pool.c`, `docs/ARENA.md` |
| Database integration | Reads, writes and auto-created model tables; migrations still open | `runtime/database.c`, `examples/posts_crud.orb`, `STAB-6` |
| Path parameters | `:id`/`{id}`/`*` match with capture, static routes win | `examples/params_service.orb` |
| Bearer auth and roles | Token extraction, role lookup, expiry; `has_role` enforced | `examples/sqlite_notes.orb`, `tests/auth/` |
| CLI consistency | Errors to stderr, per-command help, `--quiet`/`--verbose`, doctor JSON | `scripts/cli_probe.py` |
| Behavior suite | Executable programs, one behavior each | `tests/suite/`, `tests/suite/README.md` |
| Parity and stability probes | Documented gate against committed goldens | `tests/parity/`, `tests/parity/README.md` |
| Editor integration | VS Code extension: highlighting, and `orbit check` diagnostics on save. No language server - `orbit` has no `lsp` subcommand. | `editors/vscode/` |
| Native machine-code backend | Not available in the current tree | `SOVER-1` in `ENGINEERING.md` |
| Distributed cluster runtime | Single-host `orbit cluster` shipped; no multi-host story | `docs/CLUSTER.md` |
| `port`/`cors`/`db`/`env` declarations | Parse and typecheck, then discarded. The generated server hardcodes port 3000 and reads an override from `argv[1]`; the C config declaration appears nowhere in the output. | `compiler/parser.orb:1023`, `compiler/route_runtime.orb:544` |
| Standard library | **13 modules, 13 of 13 compile and merge into one program.** Was 20, with 13 compiling. Six were deleted because each was a function that returned a value and was not computing it; two are quarantined as `*.orb.quarantined`, because the language cannot express them and the alternative was to ship something that looked like the feature. One module (`std/convert/`) is new. | `std/`, `tests/std/test_imports.orb`, `std/quarantine/README.md` |
| `std/` test coverage | **17 files, 17/17 pass**, one of them declared `known-failing` so a fix arrives as a red run | `tests/std/`, `scripts/test_suite.py --dir tests/std` |
| Sockets / threads / bitwise / `Option` | **Do not exist** - not in the language, not in the runtime. The modules that claimed them are deleted or quarantined | `docs/KNOWN_LIMITATIONS.md` |

## Verification Workflow

The supported development workflow is a C compiler plus a stock `python3`. Nothing else is required for build, verification, installation, or release of the self-hosted compiler.

From the repository root:

```sh
python scripts/build_selfhost.py --cc <gcc-or-clang> --check-stale
python scripts/verify_seed.py --cc <gcc-or-clang>
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/negative_gate.py --compiler <path-to-orbit>
python scripts/frontend_gate.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/unknown_census.py --cc <gcc-or-clang> --compiler <path-to-orbit>   # report only, never fails
python scripts/unknown_ratchet.py --cc <gcc-or-clang> --compiler <path-to-orbit>  # one-way ratchet
```

The CI contract is defined in `.github/workflows/ci-gate.yml`. It covers the self-host gate on Ubuntu and Windows, canonical seed verification, parity probes, runtime C tests, and the Orbit behavior suite, plus the four gates added in September 2026.

**Read the `enforces` column before assuming a tool is holding anything.** A
gate that only counts looks exactly like a gate that blocks, right up until you
notice that it does not. That is not hypothetical here: the unknown census used
to be the only tool, it was report-only, and when the probe behind it stopped
building the only symptom was a line on stderr — while a person quoted the
number twice, authoritatively, without checking that the thing producing it
still worked. A tool in `scripts/` must therefore either have a gate or have an
aliveness check, because a tool that cannot fail is not a tool.

| gate | enforces | what it is | today |
|---|---|---|---|
| `scripts/negative_gate.py` | **blocking, and a one-way ratchet** | every program in `tests/negative/` that must **not** compile, one per defect class, each asserting the diagnostic text its header names. The gate also fails when a diagnostic *improves*, so the wording of every rejection is pinned | green, with **19 known defects the compiler still accepts** on the released canonical — the gate fails if one starts being rejected. 17 of them remain on the current tree, where signed division (`672151c`) and the integer-literal range check are fixed but not yet promoted. All nineteen are written up with their wrong values in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) |
| `scripts/frontend_gate.py` | **blocking** | `orbit frontend` against `tests/frontend/expected/`. `orbit frontend` previously had **no** CI coverage at all | **6/6.** Two fixtures could not build for most of this cycle (`compiler/lexer.orb` called `orbit_os_write_stderr_selfhost` without importing `compiler/extern.orb`); both missing imports are fixed and both fixtures now run |
| `scripts/unknown_census.py` | **reporting only — cannot fail** | how much of the corpus the front end types `unknown`. `continue-on-error: true`, output to the job summary | a measurement, never a threshold: **30.5%** of 37,628 instructions, **46.4%** of those with no diagnostic at all |
| `scripts/unknown_ratchet.py` | **one-way ratchet** | reads the census output, compares two of the counts against a committed baseline in `scripts/baselines/`, fails if either went **up**. Does *not* fail for being high — 30.5% is the number the type work has to be scoped against, and a zero-bar gate is a gate everybody deletes | holds: `unknown_instructions` 11480/11480, `unknown_without_diagnostic` 5332/5332 |

`ci-gate.yml` is the authority on which of these runs on every push; the two
`unknown_*` tools are the pair to look up there, because "the census is a gate"
and "the census is a measurement" were both true at different times and only one
of them is true now.

The census number is the honest measure of how far the type system has to
go, and it is what nineteen of the compiler's accepted defects are made
of. `checkCompatibility` (`compiler/sema.orb:326`) returns true when
*either* side is `unknown`, and that one line is why most of the list
exists; see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md#nineteen-programs-the-compiler-should-reject-and-does-not).

## Active Workstreams

### Compiler Trust

**Priority:** P0  
**Status:** active

The self-hosted pipeline is the source of truth, but the engineering catalog still records an incomplete combined route, model, and database parity surface. The next compiler changes should be narrow, differential-tested, and followed by fixed-point promotion. Self-builds of `compiler/main.orb` run in about 35 s wall on a two-core box, and the self-host chain (`verify_seed.py`) in 10-27 s depending on cache state; see [PERF.md](PERF.md) for the measured before/after and the commands.

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
**Status:** single host shipped, multi-host deferred

`orbit cluster up/status/drain/restart/down/logs` is part of the public CLI and supervises N processes of one service on one machine (see [Cluster](CLUSTER.md)). Multi-host operation is not: membership, gossip, leader coordination, and cross-node routing are still to be designed, and a single node's health, drain, and failure behavior should mature first.

## Open Risks

| Risk | Impact | Current response |
|---|---|---|
| Generated C relies on warning suppression and broad casts | Silent miscompilation or toolchain-specific failures | Track as `STAB-3`; add strict compilation incrementally |
| Engineering catalog contains historical paths and stale status details | Contributors may choose the wrong implementation surface | Use this snapshot and `docs/README.md` as navigation; reconcile the catalog progressively |
| Behavior suite is small relative to the language surface | Regressions can escape CI | Grow the suite by contract area, starting with focused tests |
| Database schema evolution is not a complete public contract | Existing services may not upgrade safely | Track as `STAB-6`; specify migrations before implementation |
| Native backend and multi-host clustering have large dependency chains | High cost and broad failure surface | Keep them behind the compiler-trust and runtime milestones |

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
