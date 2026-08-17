# Orbit Engineering Manifesto & Implementation Roadmap

> This document is the **authoritative contract** for every agent, contributor, or system that touches the Orbit codebase.
> It is not aspirational prose. It is an enforceable specification. Every section translates directly into code that compiles, tests that pass, and behaviour observable by a user.

---

## 0. The Non-Negotiable Law: No Phantom Code

**Phantom code** is any line of code whose sole existence is to signal future intent rather than deliver present function. It includes, but is not limited to:

- `// TODO: implement this`
- `std.debug.print("[Notice] Feature scheduled for 0.2.0 release.", .{});`
- Empty function bodies that return without error or a meaningful default
- `_ = param;` on an argument that should drive behaviour
- Struct fields declared but never read or written
- Tests that `expect(true)` unconditionally

**Every agent touching this codebase must abide by this invariant:**

> **A function either performs its stated contract fully, or it does not exist.**

If a feature is genuinely deferred, it must not appear in the public CLI surface, must not print banners, and must return `error.NotImplemented` from an internal API — never from a user-facing command. A user-facing command that is not implemented must not be registered.

The current violation in `src/main.zig:2142` (`runClusterMode`) is catalogued as debt item **CLUSTER-0** below.

---

## 1. Performance Targets: Non-Negotiable Minimums

Orbit competes with Go, C, C++, and Java for production server workloads. These numbers are not aspirational. They are the minimum pass criteria for any production release tag.

| Property | Target | Measurement Method |
|---|---|---|
| Throughput | ≥ 1 000 000 RPS single-node (HTTP/1.1 keep-alive) | `wrk -t12 -c400 -d30s` on loopback |
| Latency P99 | ≤ 2 ms at 500K RPS sustained | same harness, percentile from wrk |
| Memory per connection | ≤ 4 KB amortised RSS delta | RSS measurement under 100K concurrent connections |
| Cluster cross-node routing | ≤ 5 ms P99 added latency | internal cluster telemetry (see §3) |
| `orbit doctor` scan time | ≤ 50 ms on 100 000 LOC project | `summary.duration_ns` in `DoctorSummary` |
| Arena alloc per request | ≤ 50 ns amortised over 1M calls | micro-benchmark in `benchmarks/arena_alloc.zig` |

No performance number is published until it is backed by a reproducible benchmark with pinned CPU governor, isolated cores, baseline comparison, and standard deviation over 5 runs. The `benchmarks/` directory is the only valid source of performance claims.

---

## 2. Orbit Doctor — Intelligent Static Analysis System

### 2.1 Current State (2026-08-15)

`src/doctor/checker.zig` implements three checks:
1. C toolchain detection — always returns `.ok`, performs no real analysis
2. Route conflict detection via raw token scanning
3. Model declaration counting

This is a **reporting tool, not an analysis engine**. It must be extended with three new analysis layers while keeping the existing checks.

### 2.2 Architecture

Doctor operates on three layers applied to every `.orb` file in the project:

```
Layer 3: Semantic Graph Analysis
  Input:  IRModule + Sema type graph (src/ir/ir.zig, src/sema.zig)
  Detects: Data-flow bugs, taint violations, unguarded shared state, arena leaks

Layer 2: AST Structural Analysis
  Input:  Parsed Node tree (src/ast.zig, src/parser.zig)
  Detects: Cyclomatic complexity, dead functions, recursive depth, hot-loop allocs

Layer 1: Token Stream Analysis  [EXISTS, INCOMPLETE]
  Input:  Raw token stream (src/lexer.zig)
  Detects: Route conflicts, hardcoded secrets, SQL injection surface, unguarded routes
```

Each layer runs independently. Results are merged into a `FullAnalysisReport` struct that aggregates findings from all three layers before rendering.

### 2.3 Layer 1: Token Stream Analyses

Implement additions to `src/doctor/checker.zig` or extract to `src/doctor/token_analysis.zig`. No AST construction needed. Budget: ≤ 5 ms per 10K LOC file.

#### Route Conflict Detection (exists — must be hardened)

Current code does not normalise path parameters. `GET /users/:id` and `GET /users/:uuid` are a route conflict but the existing detector misses it.

Fix: before inserting into `route_map`, normalise the path by replacing any token that begins with `:` or `{` with the literal string `{}`.

Additionally detect wildcard precedence: if `GET /api/*` is registered after any `GET /api/<specific>`, emit `.warning`.

#### Hardcoded Secret Detection (new)

Scan all `StringLiteral` token values for these case-insensitive prefixes:

```zig
const SECRET_PREFIXES = [_][]const u8{
    "sk-",        // OpenAI / Stripe secret key
    "ghp_",       // GitHub Personal Access Token
    "AKIA",       // AWS Access Key ID
    "-----BEGIN", // PEM private key or certificate
    "password=",  // Inline credential
    "secret=",    // Inline secret
    "token=",     // Inline token
    "apikey=",    // Inline API key
};
```

For each match: emit `.err` with file path, line number, and the matched prefix only. Do NOT include the full string value in the diagnostic output — that would re-expose the secret.

#### SQL Injection Surface Detection (new)

When a `StringLiteral` token contains any of the SQL keywords `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `DROP` (case-insensitive substring search) and is followed within 3 tokens by an `InterpStringLiteral`, flag as `.warning`:
`"Interpolated string used in SQL context at <file>:<line>. Use parameterised queries."`

#### Unauthenticated Mutable Route Detection (new)

For every `route_decl` whose method is `POST`, `PUT`, `PATCH`, or `DELETE`: scan the token stream of its body block. If no `KeywordRole` or `KeywordReq` token appears before the first `KeywordOk` or `KeywordReturn`, emit `.warning`:
`"Mutable route <METHOD> <path> has no role guard or request validation block."`

### 2.4 Layer 2: AST Structural Analyses

Implement in `src/doctor/ast_analysis.zig`. Requires invoking `src/parser.zig` for each `.orb` file inside a `catch` that converts parse errors to `.warning` diagnostics rather than aborting the run. Budget: ≤ 20 ms per 10K LOC.

#### Cyclomatic Complexity

For each `fn_decl` node, walk the subtree and compute:
- Base: 1
- +1 per: `if_stmt`, `while_stmt`, `for_stmt`, `loop_stmt`, each arm of `match_stmt`, each `rescue_expr`

Thresholds:
- ≤ 10 → pass
- 11–20 → `.warning` "Function complexity {n}: consider extracting sub-functions"
- > 20 → `.err` "Function complexity {n} exceeds safe limit for production code"

#### Recursive Call Depth Without TCO

Build a call graph from all `fn_decl` nodes in the file. Use DFS to detect cycles (recursion). For each recursive function: verify that every branch's final statement is a `return_stmt` whose expression is a `call` node targeting the same function (tail position). If not: emit `.warning`:
`"fn <name> is recursive but not in tail position — may exhaust the call stack under sustained load."`

#### Allocation Inside Hot Loops (new)

For any `fn_decl` whose body contains a `for_stmt` or `while_stmt`: walk the loop body subtree for `call` nodes whose callee identifier matches `list_create`, `map_create`, or the suffix `_alloc`. If found: emit `.warning`:
`"Allocation inside loop body in fn <name> at <line>. Consider pre-allocating and reusing outside the loop."`

#### Dead Function Detection (new)

A `fn_decl` that does not appear in the callee set of any `route_decl`, `schedule_decl`, or another reachable `fn_decl` is unreachable. Emit `.warning`:
`"fn <name> is never called from any route or schedule and will not be compiled into the output binary."`

### 2.5 Layer 3: Semantic Graph Analyses

Implement in `src/doctor/semantic_analysis.zig`. Requires invoking `src/sema.zig` and `src/ir/builder.zig`. Budget: ≤ 30 ms per 10K LOC.

#### Unguarded Mutable Shared State

Any `var` declared at module scope (not inside a `fn_decl` or `route_decl`) that appears as the destination of a `store_var` IR opcode inside a `route_decl` or `schedule_decl` handler is a race condition. Emit `.err`:
`"Module-level mutable variable '<name>' written from concurrent handler without synchronisation. This is a data race."`

#### Taint Propagation for HTTP Inputs

Every value that originates from a `req` block field is tainted at source. Walk the IR data-flow graph. If a tainted register reaches a `db_set`, `db_get`, or `db_where` opcode without passing through a type-narrowing or explicit validation instruction, emit `.err`:
`"Untrusted request field '<name>' flows into database operation at <file>:<line> without validation. Possible injection risk."`

#### Arena Leak Detection

Track every `alloc` IR opcode inside a function body. Walk all paths from that opcode to `ret`. If any path does not contain a `free` opcode for the same allocation site and does not exit through an arena scope boundary, emit `.warning`:
`"Possible unfreed allocation in fn <name> at <file>:<line>. Verify this is covered by an arena scope."`

### 2.6 Implementation Contract

Every analysis added to Doctor must satisfy all of the following before it is considered done:

1. A test in `src/tests.zig` that provides a synthetic `.orb` source string triggering the finding, runs the analysis, and asserts the exact diagnostic severity, file, and line number.
2. Completion within the per-layer time budget. The `DoctorSummary` struct must record the duration of each layer separately.
3. No panic on malformed input. Parser and lexer invocations are always wrapped in `catch |err| { emit_parse_failure_warning(file, err); continue; }`.
4. Every finding includes: file path, line number, diagnostic code (e.g. `DOC-L1-002`), severity, and a one-sentence actionable suggestion.

### 2.7 Expected Output After Full Implementation

```
  Orbit 0.1.0-rc.2 (Doctor)

  Toolchain & Environment
  ✓ C Backend Compiler       Zig CC / x86_64-windows
  ✓ Runtime Engine           Kynx Multithreaded Arena (Zero-Trust)

  Token Analysis   [3 files, 2.1 ms]
  ✓ Route Conflicts          0 collisions across 12 endpoints
  ✗ Hardcoded Secret         api/auth.orb:14  DOC-L1-002  Literal matches 'sk-' prefix
  ! SQL Injection Surface     api/search.orb:38  DOC-L1-003  Interpolated query; use params

  AST Analysis     [3 files, 11.4 ms]
  ! Cyclomatic Complexity    handlers/user.orb:82  fn process_user — complexity 17
  ✓ Recursive Safety         All recursive functions are tail-recursive
  ✓ Loop Allocations         No allocations in hot loop bodies
  ✓ Dead Functions           All declared functions are reachable

  Semantic Analysis  [3 files, 19.7 ms]
  ✗ Taint Flow               handlers/note.orb:44  DOC-L3-002  req.id → db_where unvalidated
  ✓ Arena Leaks              No leaks across 12 allocation sites
  ✓ Shared State             No unguarded mutable shared state

  ✗ Status   2 error(s), 2 warning(s) (33.2 ms)
```

---

## 3. Orbit Cluster — Distributed Production Orchestration

### 3.1 Current State (2026-08-15)

`src/main.zig:2142` — `runClusterMode` — prints a placeholder notice and exits with code 0. **This is a lie to the user and must be removed immediately (debt item CLUSTER-0).**

**Rule**: `cluster` must not appear in the CLI dispatch table or the help text until Phase 1 below is fully implemented and integration-tested.

### 3.2 What a Cluster Is

An Orbit cluster is a set of `orbit` processes on separate hosts or ports that collectively serve one logical application. Properties:

- **Leaderless reads**: any node handles read requests
- **Leader-coordinated writes**: a single elected leader coordinates writes
- **Self-healing**: nodes detect failures via gossip heartbeat and redistribute load automatically
- **Zero-configuration**: nodes discover peers via a seed address or LAN multicast, not a central registry

### 3.3 Phase 1: Node Identity, Gossip, Routing, Leader Election

Implement in `src/cluster/`. All files are new. None of this code exists yet.

#### `src/cluster/node.zig`

```zig
pub const NodeId = struct {
    host: [64]u8,      // null-terminated hostname or dotted-decimal IP
    port: u16,
    generation: u64,   // monotonically increasing — bumped on each restart
};

pub const NodeState = enum { alive, suspected, dead };

pub const ClusterNode = struct {
    id: NodeId,
    state: NodeState,
    last_heartbeat_ns: u64,  // nanosecond timestamp from std.Io.Clock
    load_score: u32,         // 0–1000 (see §3.5)
};
```

#### `src/cluster/gossip.zig`

Push-pull gossip over TCP. Every 500 ms, each node selects 3 random peers and sends its full membership table as a compact binary frame. The receiver merges using last-write-wins on `(node_id, generation)`. A node missing more than 3 consecutive gossip cycles transitions to `suspected`; after 2 more it transitions to `dead`.

Wire format (fixed-width, no JSON, no text):

```
Offset  Len  Field
     0    4  Magic: 0x4F524243 ("ORBC")
     4    2  Protocol version: 1 (u16 little-endian)
     6    2  Node count N (u16 little-endian)
     8   N*31  Node records:
               [0..15]  host, null-padded
               [16..17] port (u16 LE)
               [18..25] generation (u64 LE)
               [26]     state (0=alive 1=suspected 2=dead)
               [27..30] load_score (u32 LE)
```

Parsing is a direct memory read into packed structs. The magic bytes allow future protocol versioning and corrupt-frame detection.

#### `src/cluster/router.zig`

When a request arrives at a node that is not responsible for the target resource shard:
1. Compute the responsible node via consistent hashing on `METHOD + URL_PATH`.
2. Forward the raw HTTP request bytes to the target over a persistent TCP connection from the per-peer connection pool (one persistent connection per peer).
3. Stream the response back to the original client without buffering the full body in userspace (stream bytes as they arrive from the target).

The connection pool is a fixed-size array of `[MAX_PEERS]?TcpConn` guarded by the Kynx arena. Reconnection is automatic on write failure.

#### `src/cluster/leader.zig`

Bully election algorithm (correct and fast for clusters ≤ 32 nodes):
1. On detecting leader absence (leader transitions to `dead` in gossip state), send `ELECTION` to all nodes with higher ID.
2. If no `ALIVE` reply within 500 ms: broadcast `COORDINATOR` self-declaration.
3. On receiving `COORDINATOR`: update local leader reference and stop any pending election.
4. On receiving `ELECTION` from a lower-ID node while alive: reply `ALIVE` and start own election if not already running.

### 3.4 Phase 2: Load-Aware Routing & Drain

After Phase 1 passes a 3-node integration test:

**Load score** computation per node. Each node tracks over a 5-second sliding window:
- `active_conns`: count of in-flight HTTP requests currently being processed
- `queue_depth`: count of accepted but not yet dispatched connections
- `p99_latency_ms`: P99 handler duration in milliseconds

Score formula: `load_score = clamp((active_conns * 0.4 + queue_depth * 0.4 + p99_latency_ms * 0.2) * 10, 0, 1000)`.

Routing prefers nodes with lower `load_score`. If all peers exceed score 900, the local node handles the request regardless of shard ownership (degraded mode).

**Drain command**: `orbit cluster drain --node <addr>` sends an out-of-band control frame (`0x4F524244` "ORBD") to the target node. On receipt, the node: (a) removes itself from gossip by broadcasting state `dead`, (b) stops accepting new connections, (c) waits for in-flight requests to complete (or a 30-second timeout), (d) exits cleanly.

**Rolling restart**: `orbit cluster restart` applies drain sequentially to each non-leader node, then drains and restarts the leader last, ensuring N-1 nodes are alive throughout.

### 3.5 Phase 3: Sovereign Network I/O

The cluster TCP stack must not depend on the C runtime's blocking `connect()`/`send()`/`recv()`. All I/O must use the platform async interface directly:
- **Linux**: `io_uring` with `IORING_OP_CONNECT`, `IORING_OP_SEND`, `IORING_OP_RECV`, `IORING_OP_POLL_ADD`
- **Windows**: `ConnectEx`, `WSARecv`, `WSASend` via IOCP completion ports

This is a hard requirement for the ≥ 1M RPS target. Blocking I/O in the gossip or routing path is a performance defect, not a known limitation.

### 3.6 Implementation Contract for Agents

1. `orbit cluster` must not appear in the help text or CLI dispatch until Phase 1 is complete and a 3-node integration test (`src/cluster/tests.zig`) passes.
2. Each cluster module (`gossip.zig`, `router.zig`, `leader.zig`) must have a unit test using loopback TCP sockets (`std.net.Server` on `127.0.0.1`) that verifies state machine transitions.
3. No `std.debug.print` in cluster code. All diagnostic output goes through a `ClusterLogger` interface parameterised on an `?std.Io.File` (null = silent).
4. The gossip wire format at version 1 is frozen. Breaking changes require bumping `protocol_version` and providing a decoder for version 1 frames.
5. Cluster state is never persisted to disk by default. It is reconstructed from gossip on startup.

---

## 4. Self-Hosting Sovereignty Roadmap

Today: **Orbit source → Zig compiler (seed) → stageN.exe → fixed-point binary**.
Goal: **Orbit source → any C compiler (seed) → stageN.exe → native binary (no C, no Zig)**.

### Phase S1: C Bootstrap Seed

**Status**: Resolved (2026-08-16). Deliverables verified end-to-end below.

**Deliverable**: `dist/orbit_bootstrap.c` — a single amalgamated C source file compilable with `gcc -O2`, `clang -O2`, or `cl /O2` on any platform, without Zig.

Steps:
1. Concatenate `compiler/selfhost/stage3.exe.c` with `src/runtime/*.c`, inlining all `#include` references to produce a single self-contained translation unit.
   - Implemented by `scripts/amalgamate.py`: recursively inlines every project-relative `#include "..."` (resolved from the including file's directory, fallback to `src/runtime`), wraps each inlined file in its own per-path include guard so an `#ifdef`-gated occurrence cannot mask a later unconditional one, and leaves system includes untouched. Output is deterministic (fixed order, LF newlines).
2. Create `scripts/build_seed.sh` (Linux/macOS) and `scripts/build_seed.bat` (Windows) that auto-detect the available C compiler and invoke it.
   - Detection order: `$ORBIT_CC`/`%ORBIT_CC%` override → `gcc` → `clang` → `cc`/`cl` → `zig cc`. Missing `dist/orbit_bootstrap.c` triggers `amalgamate.py` first. `-O2` plus the same `-Wno-int-conversion`/`-Wno-incompatible-pointer-types` suppression the pipeline uses for its own generated C.
3. Verify: the binary produced by the C seed must generate a byte-identical `stage3.exe.c` to the one produced by the Zig seed. This is the C-bootstrap fixed-point integrity check.
   - Verified locally: `dist/orbit_seed.exe` (amalgamated `stage3.exe.c` compiled with `zig cc`) run against `compiler/main.orb` emitted `orbit_selfhost_build.c` hash `9752AAECB1F00759FD4220612D46A3A4DD3A89A52813FC88D016A9D444B64136`, byte-identical to the canonical stage-3 build. Full chain via the seed (seed2 → chain2 → chain3) plus the Zig-bootstrap stages all hash `EFC1C576749A39D28850CF5B87E046AA89F38C5ED4B50E7E4EA4AE8C3A39378B` after `zeroPeTimestamp`.
   - The self-hosted pipeline already consumes `ORBIT_CC` → `CC` → `zig cc` (`compiler/pipeline.orb`), so a gcc-only machine sets `ORBIT_CC=gcc` once and bootstraps without Zig. A necessary blocker fix shipped with this item: `orbit_os_exec_selfhost` was untyped in sema, so `compOutput.indexOf(...)` in the self-host source emitted an undeclared `compOutput_indexOf`; sema/IR now type it `string` (`codegen.compile.selfhost_exec_indexof_typing` regression test).

**Gate**: A user with only `gcc` and no Zig installation must be able to fully bootstrap Orbit from source. `zig build` must not be required.

### Phase S2: Native Backend in Orbit Source

**Deliverable**: `compiler/native/` — Orbit source modules replacing `src/backend/` (currently Zig).

Required ports (differential-tested: Zig impl and Orbit impl must produce identical machine code for the same IR):
- `src/backend/x86_64/lowering.zig` → `compiler/native/lowering.orb`
- `src/backend/x86_64/encoder.zig` → `compiler/native/encoder.orb`
- `src/backend/pe_image.zig` → `compiler/native/pe.orb`
- `src/backend/lir/regalloc.zig` → `compiler/native/regalloc.orb`

### Phase S3: Pure Native Self-Hosting

**Deliverable**: `orbit bootstrap --backend=native` completes stage1→stage2→stage3 with no `.c` file emission, using only the native x86-64 backend.

**Gate**: `stage3_native.exe` and `stage3_c.exe` must produce byte-identical output for any valid `.orb` program.

---

## 5. Quality Gate: Definition of Done

A feature is **done** when ALL of the following are true simultaneously:

- [ ] All specified behaviour in this document is implemented in executable source (no stubs, no notice strings)
- [ ] Every code path has a corresponding test in the relevant `tests.zig`
- [ ] `zig build test --summary all` reports 0 failures
- [ ] `orbit doctor` produces no new errors or warnings for the new code itself
- [ ] `orbit bootstrap` still converges — SHA-256 of `stage3.exe.c` and `stage4.exe.c` are identical; both hashes are reported in the commit message
- [ ] No `std.debug.print` in production code paths (only behind explicit `--verbose`/`--debug` flags)
- [ ] The feature has documentation in `docs/` with: purpose, usage example, invariants, known limitations

---

## 6. Stability Roadmap

Tasks that materially harden the compiler against regressions, silent
miscompilations, and bootstrap breakage. Ordered by stability impact. Each item
records its Definition of Done so completion is machine-checkable.

| ID | Area | Description | DoD / Gate | Status |
|---|---|---|---|---|
| STAB-0 | CI | Fixed-point gate on every push: full 3-stage bootstrap, freshly regenerated seed, and C byte-identity must all pass automatically. | A CI job runs `scripts/verify_seed.py --bootstrap`; any hash drift fails the run. | ✅ Resolved (2026-08-16): `seed-gate` job in `.github/workflows/ci-gate.yml` on ubuntu+windows; runs `zig build`, `zig build test`, then `verify_seed.py --bootstrap` (5/5 checks). |
| STAB-1 | Scripts | One-command seed verifier replacing the manual 5-step regeneration (`scripts/verify_seed.py`): regen stage3 C → amalgamate → build seed → compare hashes (C and binaries, zeroed PE timestamp). | `python scripts/verify_seed.py` exits 0 and prints `MATCH` for C and binaries. | ✅ Resolved (2026-08-16): `scripts/verify_seed.py` — hermetic by default; `--bootstrap` regenerates the canonical via the Zig lineage and establishes `stage3.exe.c` on clean checkouts. Verified 5/5 on Windows: seed C `9752aaec…` == canonical, chain + fresh stages byte-identical (`15066da8…` after zeroing). |
| STAB-2 | Self-host | Remove the dual-compiler drift: the Zig frontend (`src/main.zig`) and the self-hosted `.orb` pipeline currently emit different C for the same source. Make the `.orb` pipeline the single source of truth (Zig becomes a thin loader). | Same input → byte-identical `temp_build.c`/`orbit_selfhost_build.c` regardless of which driver produced it. | 🚧 In progress (2026-08-17): PARITY-0 fixed — selfhost now reports parse/sema errors cleanly with **byte-identical** diagnostics to Zig (probe matrix r1..r11/c1..c4/e1..e4). PARITY-1 resolved — full route codegen port (router + server) shipped: `r9_route_empty.orb` emits **byte-identical** C to the Zig frontend (19042 B; the single differing line, the FNV-1a hash literal, fixed) and links to a runnable exe with the newly added `-DORBIT_WITH_NET`. PARITY-3 resolved — route-body parity closed: ported `return ok [status] expr` and `err code msg` statements, inlined literal payloads as constant `arg` operands, and aligned the pointer-ret / call-arg cast policy so `r1_route_only.orb` emits **byte-identical** C to the frontend. Fixed point regenerated via `verify_seed.py --bootstrap` (5/5, canonical `68bd01b9…`, chain `90812c1d…`). PARITY-4 resolved — route-path type emission parity: `model`/`enum`/`union` declarations now also emit in the router path (`generateRouteTypeDecls`) with the frontend's exact format (anonymous `typedef enum` + `#define <Type>_COUNT`, typed union payload members via new `variantPayloads` → `richVariants` plumbing, varargs model constructors). `r12_route_err.orb` (route+model), `r13_route_model_enum.orb` (route+model+enum+union) and `c2_model_route.orb` are now **byte-identical** to the frontend; `r1`/`r9` unchanged. Fixed point re-verified via `verify_seed.py --bootstrap` (5/5, canonical `09fbd284…`, chain `52cbbb80…`). |
| STAB-3 | Codegen | Clean C emission: drop the `-w` / `-Wno-int-conversion` crutches and the `(void*)(uintptr_t)` pointer/int conflation in generated C. | Every generated C compiles under gcc/clang with `-Wall -Werror -O2`; `build_seed` and pipeline drop the suppression flags. | Open |
| STAB-4 | Tests | 150/150 green. Resolve the 2 OOM-skipped tests via the `std.Io.Threaded` local pattern (no shared stdout). | `zig build test` reports `X passed; 0 skipped; 0 failed`. | ✅ Resolved (2026-08-16): `runtime.arena_epochal_tests` now uses a dedicated `Threaded` io with `page_allocator` (global_single_threaded OOMs on Windows spawns); `bootstrap.fixed_point_verification` now runs `orbit.exe bootstrap --verify` for real instead of skipping. Direct run: **All 101 tests passed** (0 skipped, 0 failed). |
| STAB-5 | IR | Type-consistency verifier over the emitted IR for the C backend (analogous to `src/backend/mir/verifier.zig`). Catches unknown-typed degradation (the `compOutput_indexOf` class of bug) at build time. | Verifier runs in `zig build test`; a deliberately unknown-typed snippet fails it. | ✅ Resolved (2026-08-16): `src/codegen/ir_verifier.zig` runs at the end of `CBackend.generate`; a `sub`/`mul`/`div`/`mod`/ordering/unknown-only `add` operand fails the build (`UnknownRegisterUse`). Scoped to respect the untyped-collection idiom (void* propagation via `decl_var`/`copy`/`arg`/`ret`/`load_field`, pointer-identity `==`/`!=`, string-concat `+`), matching `c_backend.orb` semantics. First run exposed and fixed 3 latent miscompiles: `orbit_response_json`/`orbit_response_error` missing from `function_return_types` (routes returned unknown dests), JSON-field member access on strings (`body.id`) typed unknown, and string-concat dests mis-typed `.int` so chained `a + b + c` degraded to `(orbit_int)(uintptr_t)` math on char*. All 153 tests green; fixed-point hash intact. |
| STAB-6 | Data | Schema versioning/migrations for models/DB (stale-row UNIQUE failures observed in the bench). | A `migrations` directive applies idempotent DDL; test covers add-column and stale-row upgrade. | Open |
| STAB-7 | Reproducibility | Cross-platform determinism test: same source compiled in different working dirs / path spellings yields byte-identical C (line endings, separators, embedded paths). | Test compiles from two dirs and asserts SHA-256 equality of generated C. | ✅ Resolved (2026-08-16): `reproducibility.cross_directory_byte_identical` in `src/tests.zig` spawns the driver from two separate CWDs and asserts `last_generated.c` is byte-identical (the Zig frontend writes it to the CWD; the probe hash was `133FD1BB.` for both dirs). Full suite green. |
| STAB-8 | Release | Ship without Zig: `release.yml` falls back to the C seed and attaches the amalgamated `orbit_bootstrap.c` to release artifacts (not the git repo). | A CI job builds the seed on a gcc-only runner and boots a server from it. | Open |

SOVER-1 (native backend port) remains the large catalogue item; STAB-0..3,
STAB-7, and STAB-8 are prerequisites or independently valuable even if SOVER-1
is deferred.

---

## 7. Debt Catalogue

| ID | File | Line | Description | Priority |
|---|---|---|---|---|
| ~~CLUSTER-0~~ | `src/main.zig` | — | ~~`runClusterMode` stub removed from CLI dispatch and help text. `runClusterMode` function deleted. (2026-08-15)~~ | ✅ Resolved |
| ~~DOCTOR-0~~ | `src/doctor/checker.zig` | — | ~~Route conflict detector now normalises path parameters via `normalizeRoutePath`. `:id`, `{uuid}`, `*` all collapse to `{}` before comparison. 6 regression tests added to `src/tests.zig`. (2026-08-15)~~ | ✅ Resolved |
| ~~DOCTOR-1~~ | `src/doctor/` | — | ~~Layer 2 (AST) and Layer 3 (Semantic) analyses did not exist. Now implemented: `ast_analysis.zig` (DOC-L2-001..004: complexity, non-TCO recursion, alloc-in-loop, dead fn) and `semantic_analysis.zig` (DOC-L3-001..003: shared mutable state race, taint-to-DB injection, unfreed allocation). Wired into `runDoctor` with per-layer timing. 7 integration tests in `src/tests.zig`. (2026-08-16)~~ | ✅ Resolved |
| ~~ARENA-0~~ | `src/runtime/test_arena.c` | — | ~~No cross-request arena isolation test. Now added `test_cross_request_sequential_isolation` and `test_cross_request_concurrent_isolation`; 27/27 tests pass. (2026-08-16)~~ | ✅ Resolved |
| ~~BENCH-0~~ | `benchmarks/` | — | ~~No HTTP dispatch latency benchmark. Now added `http_dispatch_latency.zig` + shim and `bench-http-dispatch` build step. Measured ~4.5M req/s, p50 ~216 ns. (2026-08-16)~~ | ✅ Resolved |
| ~~PAR-0~~ | `src/codegen/runtime_loader.zig` | 317 | ~~`num_workers <= 0` collapsed to 1, silently discarding the "0 = auto-detect CPU count" contract in `src/atlas.zig`. Now resolves to `ORBIT_WORKERS` env, else `ORBIT_CPU_COUNT()`, clamped to [1,64]. Banner prints the live worker count. NOTE (2026-08-16): the original "2.04x scaling 1→2 workers" was a hidden-console log artifact (shared stdout cap ~2500/s), NOT a valid parallelism baseline. Honest verification: perfect 50/50 socket distribution, per-request cycles flat across workers, 0% idle CPU — see PAR-2.~~ | ✅ Resolved |
| ~~PAR-1~~ | `src/codegen/c_backend.zig` | 171 | ~~Per-request log printf (`orbit_log_request_fmt`) and Kynx lease create/destroy were ALWAYS emitted by codegen regardless of `logs: disabled`/`kynx: disabled`, serializing every worker on the CRT stdout lock. Now gated: `#define ORBIT_LOGS_ACTIVE {d}` / `#define ORBIT_KYNX_ACTIVE {d}` compile the log printf and lease path out of the router (5 log call sites + kynx block + 4 destroy sites wrapped in `#if`). Golden snapshot updated. `zig build test` 0 failures. (2026-08-16)~~ | ✅ Resolved |
| ~~PAR-2~~ | `benchmarks/dynamic/run_dynamic_bench.py` | 70 | ~~Benchmark builds ran from the wrong CWD so `benchmarks/dynamic/orbit.atlas` (logs/kynx disabled) never applied. Harness now builds Orbit with `cwd=BASE` so the atlas is picked up. Measurement findings on this 2-core Celeron: distribution is perfect (50/50 per worker), server-measured per-request cycles are flat/better with more workers (29.6k/25.3k/25.3k for 1/2/4 workers), idle CPU is 0% for any worker count, and 2 clients pinned to separate cores saturate a 1-worker server at 81.6k req/s (87% CPU) while 2 workers go hungry (clients pump only ~40k/s). Conclusion: the acceptor + lock-free queue design is correct; end-to-end throughput scaling is client-limited on this box because a single local client competes with the worker threads for 2 physical cores. Demonstrating scaling requires >=3 cores (2 workers + 1 client) or a remote client. (2026-08-16)~~ | ✅ Resolved (measurement) |
| ~~COMPILE-0~~ | `benchmarks/marketing_suite/servers/02_auth_server.orb` | — | ~~Does not compile. Codegen: `no member named 'body' in 'struct OrbitModel'` — request model field access emitted against the wrong C struct.~~ Resolved (2026-08-16): `req.*` value access lowered to `orbit_http_body_get`/`orbit_http_param_get`, pipelined parser no longer clobbers the request buffer between keep-alive reads, bench harness builds with `-o` and provisions `sqlite3.dll`. | ✅ Resolved |
| ~~COMPILE-1~~ | `benchmarks/marketing_suite/servers/03_page_cache_server.orb` | — | ~~Does not compile. Parser: `unexpected token 'TypeSet'` — syntax rejected at parse time, pre-existing.~~ Resolved (2026-08-16): contextual keywords — member names after `.` accept any keyword/type token and resolve by text, so `cache.set(...)` parses. Regression test `codegen.compile.cache_member_contextual_keyword`. | ✅ Resolved |
| ~~COMPILE-2~~ | `examples/catalog_service.orb` | — | ~~Does not compile. Codegen builtin arity mismatch on `orbit_http_query_get`, `orbit_db_query_where`, `orbit_http_body_get`.~~ Resolved (2026-08-16): injected `req`/table operands counted in call arity; `Model.where(cond, param)` lowers to new `orbit_db_query_where_p` (sqlite3_mprintf `%Q` binding); `req.body/param/file` typed string and `body.id` on a JSON string emits `orbit_json_field` (was a struct cast that dereferenced raw JSON bytes and crashed the server). Regression test `codegen.compile.catalog_member_call_arity`; POST /v1/catalog/items verified 201 end-to-end. | ✅ Resolved |
| TY-0 | `src/ir/builder.zig` | `getNodeType` (`.call`/member branch) | Typing every member CALL on a string as `.string` (beyond `at`→int / `slice`→string) crashes the 3-stage bootstrap: string members like `indexOf` return int/bool, so the mis-typed dest register feeds wrong lowering and `stage1.exe` segfaults (0xC0000005) when building stage2. Only the bare `.member_access` node path was fixed to return `.string` (JSON field lookup, `body.id`); the `.call` receiver branch stays conservative. The verifier (STAB-5) already runs after codegen to catch the surviving unknown-typed classes. | **Low** |
| ~~SOVER-0~~ | `scripts/` | — | ~~No C bootstrap seed or build scripts. Zig is required to bootstrap.~~ Resolved (2026-08-16): `dist/orbit_bootstrap.c` amalgamated from `stage3.exe.c` + runtime (`scripts/amalgamate.py`); `scripts/build_seed.sh`/`.bat` auto-detect the C compiler; seed C fixed-point verified byte-identical to the Zig bootstrap (`orbit_selfhost_build.c` `9752AAEC…`, chain binaries `EFC1C576…`). Blocker fix shipped: `orbit_os_exec_selfhost` typed `string` in sema/IR so `result.indexOf(...)` lowers to `orbit_string_indexOf` (was undeclared `compOutput_indexOf`). Regression test `codegen.compile.selfhost_exec_indexof_typing`. | ✅ Resolved |
| PARITY-0 | `compiler/c_backend.orb` (`load_field`/`findFieldOwner`), fixed in `ast.orb`/`parser.orb`/`builder.orb` | `findFieldOwner` (1991) | The self-host seed **segfaulted (0xC0000005)** on the canonical route syntax `route GET "/p"` and on **every** parse error (garbage `Token.line`, e.g. `line -467998816`). ROOT CAUSE (2026-08-16): `load_field` resolves the field owner **by field name only** when the receiver's static type is unknown; `ParserDiagnostic {message,line,column}` and `TirDiagnostic {severity,code,message,line,column}` share `message`/`line`/`column` and `TirDiagnostic` is registered last, so `diag.line` compiled to `((TirDiagnostic*)r)->line` (offset 24 vs 8) and `diag.message` read `column` as a string pointer → crash in `orbit_string_concat`. The receiver type was unknown because `buildVarDecl` **discarded** `val diag: ParserDiagnostic` annotations. FIXED (2026-08-16): plumb the annotation through `ast.orb` (`VarDeclNode.typeAnnotation`), `parser.orb` (`parseVarDecl` stores it), `builder.orb` (annotation wins over `inferValueType`), so `fieldOwnerForObject` qualifies the fieldRef and the cast is correct. Verified: selfhost and Zig emit **byte-identical** diagnostics across the full probe matrix (r1..r11, c1..c4, e1..e4); canaries still compile (exit 0); fixed point regenerated via `verify_seed.py --bootstrap` (4/4, canonical `782ce88d…`, chain `9880c068…`). | ✅ Resolved |
| PARITY-1 | `compiler/optimizer.orb` → `compiler/c_backend.orb` (`generateRouterBlock`/`generateServerMain`/`fnv1a64Hash`), `compiler/pipeline.orb` | — | Even with the parser workaround (`route "GET" "/p"`), the seed failed inside `optimizeIRModule` after `buildAST` (exit 1, no C written). RESOLVED (2026-08-17) with the STAB-2 D–F codegen port: `compiler/route_runtime.orb` (preamble/router/server static text), `moduleHasRoute` + `hasRoutes` branching in `generateC`, `generateRoutePreamble`/`generateRouterBlock`/`generateServerMain`, and a limb-based `fnv1a64Hash`. Two selfhost-miscompile bugs found en route: (1) the 64-bit FNV prime is `0x100000001B3 = 2^40 + 0x1B3`, NOT `2^32 + 0x1B3` — the `h << 40` term was missing, so the hash literal was wrong; (2) `while ri >= 0` reverse loops never terminate because selfhost ints are unsigned (`uintptr_t`) — `ri` underflows to a huge value and `>= 0` is always true, so reverse iteration must use `while n > 0 { n = n - 1; … }`. Also added the missing `-DORBIT_WITH_NET` to the selfhost `zig cc` invocation (pipeline.orb) so route C compiles. Verified: `r9_route_empty.orb` C is **byte-identical** to the frontend oracle (19042 B) and links to a runnable exe. | ✅ Resolved |
| PARITY-2 | `compiler/lexer.orb` | `nextToken` (150) | The self-host lexer rejects the UTF-8 BOM (`EF BB BF`) as `Lexer error: invalid character (code 239/187/191)`; the Zig frontend tolerates it. Minor parity gap, trivially fixable once PARITY-0/1 are addressed. | **Low** |
| PARITY-3 | `compiler/*.orb` | — | Observed from the STAB-2 drift probe: the seed only ever compiles `compiler/main.orb` in the fixed-point (221 functions), so no `route`-bearing program exercised the self-host parser/builder/optimizer/codegen. PARTIALLY ADDRESSED (2026-08-17): an empty route (`r9`) now produces **byte-identical** C to the frontend through the full router/server codegen path. Remaining gap: non-empty route bodies still differ — e.g. `r1_route_only` the frontend inlines the local `ok` helper (`r_0 = orbit_response_json(arena, 200, "hi")`) while the selfhost emits an un-inlined call (`uintptr_t ok = 0; r_0 = (void*)(uintptr_t)(ok);`) plus the retNone/`return NULL;` fallthrough. Next step is helper inlining / const-folding parity on route bodies. | ✅ Resolved (2026-08-17): ported `return ok [status] expr` (token `KeywordOk`, `ReturnOkNode`, parse `return ok`, builder emits `arg(int status)` + `arg(payload)` + `call orbit_response_json` + `ret`, register type `"response"` → `OrbitResponse*`, `arena` prepended via `arenaFirst`) and the bare `err code msg` statement (`ReturnErrNode`, `orbit_response_error`). Literal payloads (string/int/char/bool) are passed as constant `arg` operands via `buildCallArgValue`, matching the frontend IR, and `orbit_response_json`/`orbit_response_error` args + dest assignment are emitted without the `(void*)(uintptr_t)` wrap. Also fixed a selfhost miscompile: `x == UnionVariant` / `x != UnionVariant` inside `if` conditions always evaluated false (union tags only dispatch correctly through `match`; `TokType` is an `enum` so its `==` worked, `IROpcode` is a `union` so its `==` never did). That bug silently added a spurious retNone (`return NULL;`) to every function whose last instruction was a ret, and made `buildAST` push `main` only "because" the comparison was always true. `r1_route_only.orb` now emits **byte-identical** C to the frontend (MD5 `E5AAA84C…`), `r9` still byte-identical, fixed point 5/5. |
| PARITY-4 | `compiler/ast.orb`, `compiler/parser.orb`, `compiler/builder.orb`, `compiler/c_backend.orb` | `generateRouteTypeDecls` | The route path skipped type/model emission entirely (wrapped in `if hasRoutes == false`), so any `route`-bearing program with a `model`/`enum`/`union` differed from the frontend — e.g. `r12_route_err` lost the `Product` struct. RESOLVED (2026-08-17): `ast.orb` adds `TypeDeclNode.variantPayloads`; `parser.orb` preserves per-variant payload types (enum/union/sum); `builder.orb` maps them to the previously unused `IRTypeDecl.richVariants`; `c_backend.orb` adds `generateRouteTypeDecls` (model/union forward typedefs, then enums/unions/aliases + models in the frontend's exact order and format: anonymous `typedef enum` + `#define <Type>_COUNT`, typed union payload members, varargs `#define M(...) (M*)orbit_model_M_create(arena, __VA_ARGS__)` constructors), and `generateRoutePreamble` drops its trailing newline so forward typedefs sit flush after the `valStr_indexOf` block. Verified: `r12_route_err.orb`, `r13_route_model_enum.orb`, `c2_model_route.orb` emit **byte-identical** C to the frontend; `r1`/`r9` unchanged; probe matrix exit codes unchanged; fixed point 5/5 via `verify_seed.py --bootstrap` (canonical `09fbd284…`, chain `52cbbb80…`). | ✅ Resolved |
| PARITY-5 | `compiler/*.orb` | — | Known route-parity gaps that the probe matrix still exercises with `exit 1` / no C written: (1) request introspection in route bodies — `req.query`, `req.body`, `req.params`, `body.<field>` (c3, r6, stab2_probe); (2) ORM-style model calls — `Product.all()`, `Product.create()`, `Product.first()` (c4); (3) quoted route method `route "GET" "/p"` (r7, r11 — the parser only accepts bare `KeywordGet`). Structural: the frontend emits the router preamble **unconditionally** (even for programs with no routes), while the selfhost keeps a minimal non-route path — this is what compiles `compiler/main.orb` in the fixed point, so non-route programs (c1, r14, trivial) have **no valid frontend oracle** for byte-identity. Route-path trait emission is also skipped (enums/unions/aliases/models are covered by PARITY-4). | Open |
| SOVER-1 | `compiler/` | — | x86-64 encoder, PE emitter, and regalloc not ported to Orbit source. | **Medium** |

---

## 8. Instructions for Agents

Read this entire document before writing any code. Then:

1. **Identify which debt item or roadmap section your task addresses.** If it is not listed here, confirm with the user before writing code.
2. **Implement the full contract.** If a section specifies 4 analyses, implement all 4. If one cannot be done due to a missing dependency, state exactly what is missing — do not silently omit.
3. **Write the test before the implementation.** If you cannot write a test for a function, the function is not well-specified. Stop and clarify.
4. **Run `zig build test --summary all` and report the exact output** before declaring completion.
5. **Run `orbit bootstrap` and report both SHA-256 hashes** after any change to `src/`.
6. **Log new debt items in §7** if you defer anything. Include file, line, description, and priority.
7. The words `TODO`, `FIXME`, `placeholder`, `stub`, `scheduled for`, `coming soon` must not appear in any committed `.zig` or `.orb` source file outside of this planning document.
