# Orbit Roadmap

This roadmap turns the current foundation into verifiable milestones. It's ordered from low-risk docs and organization work toward compiler, runtime, backend, and distributed work. Every phase ends with something you can run, not just something you can read.

## Direction

Orbit should become a self-hosted systems language for reliable network services:

```text
Orbit source -> reproducible compiler -> native executable -> observable service
```

The project already has a self-hosted compiler, a C bootstrap seed, a fixed-point verification flow, an HTTP runtime, and cross-platform CI. The next step is to make those foundations easier to trust, use, and extend.

For the dated implementation snapshot, current verification commands, and active risks, see [Project Status](STATUS.md).

## Working Rules

- Every phase ends with an executable gate, not only documentation.
- Compiler source changes must preserve the fixed point or deliberately promote a new canonical C artifact.
- New public features require an example, a test, and documentation.
- Performance claims belong to a reproducible command, with hardware and configuration recorded.
- Large features remain out of the public CLI until their integration contract is implemented and tested.

## Phase 0: Project Clarity

**Status:** Complete for documentation; automation and release evidence remain active.

**Goal:** establish one current description of the project.

Tasks:

- Keep this roadmap separate from detailed engineering contracts.
- Delete historical seed material rather than annotating it, wherever it is no longer load-bearing.
- Maintain a support matrix for Windows and Linux, including C compiler requirements.
- Define the release and compatibility policy for the language and standard library. See [Versioning and Compatibility](VERSIONING.md). ✅
- Document release artifacts and their verification. See [Release Artifacts](RELEASES.md). ✅
- Keep the README focused on installation, first use, and links to deeper documentation.

**Exit gate:** a new contributor can identify the supported workflow, current architecture, active risks, and required verification commands without reading historical notes.

## Phase 1: Compiler Trust

**Status:** Active.

**Goal:** make the self-hosted compiler safer to change.

Priority tasks:

1. Complete the remaining self-host parity work in `compiler/`.
2. Expand the language behavior suite into a categorized regression matrix.
3. Reduce unknown-type propagation in the IR and generated C.
4. Replace avoidable pointer/integer casts with typed emission.
5. Compile generated C with warnings enabled and progressively adopt `-Werror`.
6. Preserve bootstrap, parity, and fixed-point gates in CI.

**Exit gate:** the same source produces equivalent output through the supported compiler paths, the generated C passes the strict warning profile, and all bootstrap/parity/suite gates pass on supported platforms.

## Phase 2: Language and Standard Library Contract

**Status:** Planned after the current compiler-trust work.

**Goal:** make Orbit practical for projects that should outlive compiler experiments.

Tasks:

- Freeze and document the semantics of types, errors, results, imports, functions, routes, models, and arena scopes.
- Add executable examples for each public language feature.
- Establish coherent APIs for strings, collections, filesystem, IO, concurrency, and HTTP.
- Add idempotent database migrations and tests for upgrading an existing schema.
- Define project and compatibility versioning.

**Exit gate:** a documented service can be created, tested, upgraded, and rebuilt without relying on compiler internals.

## Phase 3: Developer Workflow

**Status:** Planned.

**Goal:** shorten the feedback loop for Orbit users.

Tasks:

- Provide `orbit check`, `orbit fmt`, `orbit test`, `orbit build`, and `orbit run` workflows where each command has a real contract.
- Turn Doctor into a stable diagnostics interface with codes, spans, severity, and actionable suggestions.
- Add formatter and linter coverage to CI.
- Improve VS Code diagnostics, symbols, formatting, and build/test tasks.
- Document the complete editor setup.

**Exit gate:** a contributor can edit, format, check, test, and run a service without manually invoking internal bootstrap scripts.

## Phase 4: Production Runtime

**Status:** Active hardening, after the compiler-trust gate.

**Goal:** make generated services dependable under real operating conditions.

Tasks:

- Add graceful shutdown, connection draining, timeouts, and configurable request limits.
- Add structured logs, request identifiers, metrics, and latency percentiles.
- Test malformed HTTP, slow clients, concurrent connections, cancellation, memory pressure, and SQLite concurrency.
- Publish baselines, variance, and environment details for every number claimed.
- Record CPU, memory, and energy methodology in [Resource and Energy Measurement](ENERGY.md).

**Exit gate:** a service has documented operational behavior and repeatable tests for failure, load, and shutdown scenarios.

## Phase 5: Native Backend

**Status:** Deferred until the IR and language contracts stabilize.

**Goal:** reduce reliance on the C toolchain without destabilizing the primary product.

Order:

1. Freeze and serialize the IR contract.
2. Implement the x86-64 lowering and encoder.
3. Implement register allocation and the target executable format.
4. Differential-test the native and C backends.
5. Ship the native backend as experimental first.
6. Make it default only after parity, bootstrap, and runtime tests pass.

**Exit gate:** valid Orbit programs produce working native binaries with behavior and diagnostics covered by the same regression suite as the C backend.

## Phase 6: Distributed Operation

**Status:** Deferred.

**Goal:** add multi-node operation only after the single-node runtime is observable and drainable.

Order:

1. Health checks and explicit request forwarding.
2. Versioned wire protocol and failure tests.
3. Connection draining and rolling restart.
4. Membership and gossip.
5. Leader coordination and load-aware routing.
6. Async platform I/O after the protocol and state machines are proven.

**Exit gate:** a three-node integration test covers startup, request routing, node failure, recovery, and graceful drain.

## Priority Order

| Priority | Area | Why now |
|---|---|---|
| P0 | Documentation and project clarity | Prevents work from following stale assumptions |
| P0 | Compiler trust and parity | Protects every later feature |
| P1 | Language and standard library | Makes Orbit a usable platform |
| P1 | Developer workflow | Lowers adoption and maintenance cost |
| P1 | Production runtime | Turns examples into deployable services |
| P2 | Native backend | Advances sovereignty after the contract is stable |
| P3 | Distributed operation | Has the highest dependency and failure cost |

## First Delivery Slice

The first implementation slice after this document should be small and measurable:

1. Refresh the active status in `ENGINEERING.md`.
2. Record the current compiler and runtime gates in one place.
3. Categorize the existing language suite.
4. Select one narrow parity gap and add its regression test before changing code.
5. Run the self-host, fixed-point, parity, and suite checks.

This sequence keeps simple writing and organization work ahead of the compiler and runtime changes that require deeper validation.
