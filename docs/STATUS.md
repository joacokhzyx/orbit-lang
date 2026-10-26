# Orbit Project Status

**Snapshot date:** 2026-10-18  
**Repository revision:** `62fb3e1` (`main`)

This document is a dated project snapshot. It is intended to answer "what is true now?" without replacing the detailed engineering contract, language reference, or architecture records. Update it when a milestone changes the supported workflow or the status of a major workstream.

Bootstrap terms (canonical, seed, seed2, chain2, chain3, promote, PUBLISHED_C, amalgamate) are defined once in the [Sovereignty glossary](architecture/SOVEREIGNTY.md#glossary---canonical-bootstrap-terms).

## Executive Summary

Orbit is a self-hosted, statically typed language and compiler for general software, with development focused on native network services for now. It compiles Orbit source to C, then uses your platform C compiler to produce the executable. You can bootstrap from the committed canonical C with the CI-verified compilers (gcc on Ubuntu, clang on Windows). Other C compilers are not exercised in CI.

The project is past the bootstrap proof-of-concept stage. Its mission is to help software do more work with fewer CPU cycles, less memory, and lower energy use. The next challenge is to make that goal measurable while tightening compiler parity, reducing unsafe type degradation in generated C, defining the public language contract, and making the runtime observable and operationally predictable.

## Current Capabilities

| Area | Current status | Evidence |
|---|---|---|
| Self-hosted compiler | Available | `compiler/**/*.orb`, `compiler/host/main.orb` |
| Bootstrap from committed C | Available | `scripts/build_selfhost.py`, `scripts/verify_seed.py` |
| Canonical C trust root | Committed and verified by the project workflow | `compiler/selfhost/stage3.exe.c` |
| C code generation | Primary backend | `compiler/emit/c_backend.orb`, `runtime/` |
| Generated C size | Measured per program and budgeted; the HTTP router block is emitted only for programs that declare a route | [Codegen budget](CODEGEN_BUDGET.md), `generateC` in `compiler/emit/c_backend.orb` |
| HTTP service runtime | Available for supported service features | `runtime/http.c`, `compiler/emit/route_runtime.orb`, examples |
| Arena-based allocation | Available | `runtime/arena.c`, `runtime/arena_pool.c`, `docs/ARENA.md` |
| Database integration | Reads, writes and auto-created model tables; forward DDL runs from `migrations "<SQL>"` lines, each once, in `_orbit_migrations` | `runtime/database.c`, `runtime/test_migrations.c`, [Migrations guide](guides/migrations.md) |
| Path parameters | `:id`/`{id}`/`*` match with capture, static routes win | `examples/params_service.orb` |
| Bearer auth and roles | Token extraction, role lookup, expiry; `has_role` enforced | `examples/sqlite_notes.orb`, `tests/auth/` |
| CLI consistency | Errors to stderr, per-command help, `--quiet`/`--verbose`, doctor JSON | `scripts/cli_probe.py` |
| Behavior suite | **101 runnable programs (102 files; `imports.support.orb` is a support module), one behavior each** | `tests/suite/`, `tests/suite/README.md` |
| Parity and stability probes | Documented gate against committed goldens | `tests/parity/`, `tests/parity/README.md` |
| Editor integration | VS Code extension: highlighting, and `orbit check` diagnostics on save. No language server - `orbit` has no `lsp` subcommand. | `editors/vscode/` |
| Native machine-code backend | Not available in the current tree | `native-backend` in `ENGINEERING.md` |
| Distributed cluster runtime | Single-host `orbit cluster` shipped; no multi-host story | `docs/CLUSTER.md` |
| `port`/`cors`/`db`/`env` declarations | `port` is read: an integer literal in 1..65535 (E1008 otherwise) becomes the default port the generated server binds; `argv[1]` still overrides it, and no declaration still means 3000. `cors`, `db`, `env` parse and typecheck with no runtime effect. | `checkConfigDecl` in `compiler/front/sema.orb`, `generateServerMain` in `compiler/emit/c_backend.orb`; live proof in `scripts/kynx_gate.py live` (declared port, then argv); see [Architecture](ARCHITECTURE.md#config-declarations-port-reaches-the-server-the-rest-are-reserved) |
| Standard library | **19 modules, and one import-all test merges all 19 into a single program**: `sys/bytes/bitwise.orb` left quarantine on 2026-10-18 and is imported like the rest. `option` stays quarantined as `*.orb.quarantined` because the language has no generic tagged union (`generic-union-params` in [the engineering contract](../ENGINEERING.md)) | `std/`, `tests/std/test_imports.orb`, `tests/std/test_bitwise.orb`, `std/quarantine/README.md` |
| `std/` test coverage | **23 files, 23/23 pass** | `tests/std/`, `make suite` |
| Sockets / threads / `Option` | **Do not exist** - not in the language, not in the runtime. The modules that claimed them are deleted or quarantined | `docs/KNOWN_LIMITATIONS.md` |

## Verification Workflow

The supported development workflow is a C compiler plus a stock `python3`. Nothing else is required for build, verification, installation, or release of the self-hosted compiler.

From the repository root, one entry point runs the gates: `scripts/dev.py`, wrapped by `make`. Windows runners have no `make`, so they call `python scripts/dev.py <target>`.

```sh
make dev      # gates proportionate to what the working tree touched (default)
make check    # T0..T2 unconditionally
make all      # T0..T3, including the root of trust, before a commit that promotes
make fp       # build the fixed-point compiler and print its version
make report   # report-only tier (census, fuzzers); never fails the build
make list     # what dev would run, without running it
make promote  # the only way to replace the committed canonical
```

A single gate, for when one thing is broken and the rest is noise: `make doctor`, `make suite`, `make parity`, `make werror`, `make negative`, `make fmt`. The scripts under `scripts/` are still the implementation, but their flags (`--cc`, the fixed-point path, `TEMP`/`ORBIT_CCACHE_DIR`) belong to `scripts/dev.py`, which owns them. Passing them by hand is how the workflow and CI drift apart.

The CI contract is defined in `.github/workflows/ci-gate.yml`. It covers the self-host gate on Ubuntu and Windows, canonical seed verification, parity probes, runtime C tests, and the Orbit behavior suite, plus the four gates added in September 2026. For the trust boundary (what is trusted vs verified, where amalgamation fits) see [Sovereignty](architecture/SOVEREIGNTY.md#trust-boundary-what-is-trusted-vs-verified). For the per-request path see [Architecture](ARCHITECTURE.md#request-path).

The `enforces` column distinguishes blocking gates from measurements:
`unknown_census.py` is report-only (`continue-on-error: true`, output to the
job summary) and `unknown_ratchet.py` is the blocking one-way ratchet over
two of its counts. A tool in `scripts/` either enforces a contract or has an
aliveness-check row, so a silently broken measurement cannot present as a
passing gate.

| gate | enforces | what it is | today |
|---|---|---|---|
| `scripts/negative_gate.py` | **blocking, and a one-way ratchet** | every program in `tests/negative/` that must **not** compile, one per defect class, each asserting the diagnostic text its header names. The gate also fails when a diagnostic *improves*, so the wording of every rejection is pinned | green, **93/93 cases hold their pinned outcome**, **0 known defects** - the last ratchet to close was F-0025, the assignment target no pass visits (`n90`-`n92`), which flipped to `expect-error:` when E1009 landed; before it, F-0009 (a bare `list` parameter with no element type) flipped when generic functions landed, and the deliberate bare-`list` leniency is documented in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) |
| `scripts/frontend_gate.py` | **blocking** | `orbit frontend` against `tests/frontend/expected/` | **6/6** |
| `scripts/unknown_census.py` | **reporting only — cannot fail** | how much of the corpus the front end types `unknown`. `continue-on-error: true`, output to the job summary | a measurement, never a threshold: **29.5%** of 72,213 instructions over 154 files, **45.7%** of those with no diagnostic at all (2026-10-18; 9,749 of 21,318) |
| `scripts/unknown_ratchet.py` | **one-way ratchet** | reads the census output, compares two of the counts against a committed baseline in `scripts/baselines/`, fails if either went **up**. Does *not* fail for being high - 29.5% is the number the type work has to be scoped against, and a zero-bar gate is a gate everybody deletes | baseline `unknown_per_mille` 296, `silent_per_mille` 135 |

`ci-gate.yml` is the authority on which of these runs on every push. See the
`enforces` column and the workflow file for the current mapping.

The census number is the measure of how far the type system has to
go, and it is what the compiler's one accepted defect is made
of. `checkCompatibility` (`compiler/front/sema.orb:1577`) returns true when
*either* side is `unknown`, and that one line is why most of the list
exists. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md#the-silent-group-is-empty).

## Active Workstreams

### Compiler Trust

**Priority:** P0  
**Status:** active

The self-hosted pipeline is the source of truth, but the engineering catalog still records an incomplete combined route, model, and database parity coverage. The next compiler changes should be narrow, differential-tested, and followed by fixed-point promotion. Self-builds of `compiler/host/main.orb` measured 33.5 s wall warm and 76.9 s on the first run of a session, on an 8-logical-core box (2026-10-18). The self-host chain (`verify_seed.py`) is cache-sensitive in the same way. [PERF.md](PERF.md) has the method and the earlier numbers.

Key work:

- finish the remaining combined ORM and route parity cases;
- reduce unknown-type propagation and pointer/integer casts in generated C;
- establish a strict warning profile for generated C;
- keep bootstrap, parity, and behavior-suite output reproducible.

### Language Contract

**Priority:** P1  
**Status:** needs consolidation

The language reference and examples cover the main syntax, but the project still needs a single compatibility policy for types, errors, imports, arenas, routes, models, and standard-library APIs. `Result` construction, returns, and `try/catch` handling are covered by the behavior suite, including binding a result to a `val` (annotated or not) and passing one as an argument, pinned by [`tests/suite/result_binding.orb`](../tests/suite/result_binding.orb). Public behavior should be specified before adding a large feature set. The broader language mission includes general software. The current server focus is driven by the opportunity to measure resource use in continuously running systems.

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
| The bootstrap builds the compiler's own unit without `-Wall` (it costs 5.7x there; see [PERF.md](PERF.md)) | A warning in generated C would not fail the bootstrap build | `make werror` compiles eleven probes - expression, IO, server, db and builtin-heavy programs - under `-Werror` and runs them; `ORBIT_BOOTSTRAP_WARNINGS=1` turns the warnings back on while hacking |
| Engineering catalog contains historical paths and stale status details | Contributors may choose the wrong implementation | Use this snapshot and `docs/README.md` as navigation; reconcile the catalog progressively |
| Behavior suite is small relative to the language | Regressions can escape CI | Grow the suite by contract area, starting with focused tests |
| Database schema evolution is not a complete public contract | Existing services cannot roll a schema back, and nothing checks the applied version at startup | Forward DDL ships: `migrations "<SQL>"` lines run once each, in declaration order, tracked in `_orbit_migrations`, covered by `runtime/test_migrations.c` and the [Migrations guide](guides/migrations.md). Missing: `down` migrations, a version-required startup check, and a standalone `orbit migrate` |
| Native backend and multi-host clustering have large dependency chains | High cost and broad failure modes | Keep them behind the compiler-trust and runtime milestones |

## Definition of a Meaningful Milestone

A milestone is meaningful when it changes one of these user-visible properties and includes evidence:

- a new supported language behavior.
- a safer or more reproducible compiler path.
- a runtime capability with failure tests.
- a documented workflow a new contributor can execute.
- a measured performance or resource improvement with a reproducible command.

Documentation-only changes may improve project clarity, but they do not close compiler or runtime milestones by themselves.

## Related Documents

- [Documentation Index](README.md)
- [Project Roadmap](ROADMAP.md)
- [Engineering Contract](../ENGINEERING.md)
- [Codegen Budget](CODEGEN_BUDGET.md)
- [Self-Hosting](architecture/SELF_HOSTING.md)
- [Sovereignty](architecture/SOVEREIGNTY.md)
- [Behavior Suite](../tests/suite/README.md)
- [Parity probes](../tests/parity/README.md)
- [Versioning and Compatibility](VERSIONING.md)
- [Resource and Energy Measurement](ENERGY.md)
- [Release Artifacts](RELEASES.md)
