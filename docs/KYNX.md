# Kynx

Kynx is the sovereign computational control layer for Orbit. It enforces $O(1)$ sharded admission control, monotonic-clock deadline tracking, and CPU instruction-boundary computational leases across all worker threads.

Unlike external middleware or proxy-based rate limiters, Kynx is integrated directly into the Orbit compiler lowering pipeline (`src/backend/x86_64/lowering.zig`) and runtime kernel (`src/runtime/kynx.c`).

---

## Architecture Overview

Kynx operates as an in-process, lock-free computational safety supervisor. It monitors incoming request pressure, active memory allocations, and execution timeouts at the assembly instruction boundary.

```
                          ┌───────────────────────────┐
                          │   Incoming Request / IP   │
                          └─────────────┬─────────────┘
                                        │
                                        ▼
                          ┌───────────────────────────┐
                          │  O(1) IP Shard Lookup     │
                          │ (OrbitKynxConfig & Table) │
                          └─────────────┬─────────────┘
                                        │
                  ┌─────────────────────┼─────────────────────┐
                  │                     │                     │
                  ▼                     ▼                     ▼
        [active leases <= 32]   [33 .. 128]           [129 .. 512]
          State: STABLE           State: SHAPED          State: GUARDED
                  │                     │                     │
                  ▼                     ▼                     ▼
          500ms / 16 MB          250ms / 16 MB         100ms / 2 MB
                                         └──────────►   [active > 512]
                                                          State: SIEGE
                                               (non-critical routes rejected)
```

Transitions are recomputed on every lease create/destroy (`kynx_update_admission_state`): upward at `>32` (SHAPED), `>128` (GUARDED), `>512` (SIEGE); downward at `<=24` (STABLE), `<=96` (SHAPED), `<=384` (GUARDED).

---

## State Machine & Admission Control

Kynx computes admission states dynamically from the **active-lease count** (not suspicion scores). Each new route lease tightens its own CPU/memory/SQL budget according to the current state.

### Admission States

| State | Active Leases | Execution Deadline | Arena Cap | DB Budget | HTTP Response Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `STABLE` | $0 \dots 32$ | 500 ms | 16 MB | 10 queries / 100 K steps | Standard processing |
| `SHAPED` | $33 \dots 128$ | 250 ms | 16 MB | 10 queries / 50 K steps | Throttled burst |
| `GUARDED` | $129 \dots 512$ | 100 ms | 2 MB | 3 queries / 10 K steps | Restricted |
| `SIEGE` | $> 512$ | 50 ms (critical only) | 512 KB | 2 queries / 5 K steps | Non-critical routes rejected immediately; `/health`, `/auth`, `/` get an emergency budget |

### O(1) Shard Lookup

IP tracking uses fixed-capacity hash table shards with Atomic Spinlocks (`orbit_kynx_lock`) to prevent thread contention during peak throughput.

```c
typedef struct {
    uint8_t family; // 4 or 6
    union {
        uint32_t v4;
        uint8_t  v6[16];
    } addr;
} OrbitKynxIP;

typedef struct {
    OrbitKynxIP ip;
    uint64_t    last_request_ns;
    int32_t     suspicion_score;
    int32_t     request_count;
    bool        is_banned;
    uint64_t    banned_at_ns;
} OrbitKynxEntry;
```

---

## Computational Leases

A **Computational Lease** (`OrbitKynxLease`) defines the strict resource boundary assigned to a single thread execution context.

```c
typedef struct {
    uint64_t deadline_ns;
    uint64_t cpu_fuel;
    size_t   arena_bytes;
    size_t   arena_limit;
    size_t   request_bytes;
    size_t   request_limit;
    size_t   response_bytes;
    size_t   response_limit;
    uint32_t db_queries;
    uint32_t db_queries_limit;
    uint64_t db_steps;
    uint64_t db_steps_limit;
    uint32_t route_id;
    uint32_t principal_id;
    uint32_t flags;
} OrbitKynxLease;
```

### Lifetime Lifecycle

1. **Lease Acquisition (`orbit_kynx_lease_create_for_route`)**:
   Emitted by the C backend at the entry of every route handler. Increments the active-lease counter, recomputes the admission state, and allocates the lease from the request arena with budgets tightened by the current state. In `SIEGE`, non-critical paths (`/health`, `/auth`, `/` exempt) receive a zero budget and the `REJECTED` flag.

2. **Instruction-Boundary Verification**:
   The native x86-64 backend lowers `MirOpcode.kynx_lease_check` into a direct call to the `kynx_check_lease` symbol at loop back-edges and recursive calls; `kynx_lease_end` is lowered to `kynx_end_lease` on handler completion.

3. **Lease Cleanup (`orbit_kynx_lease_destroy`)**:
   Decrements the active-lease counter and recomputes the admission state. Per-budget enforcement runs through `orbit_kynx_lease_check_limits(additional_response_bytes)`, which validates response size and the deadline.

---

## Compiler Lowering Integration

The x86-64 backend (`src/backend/x86_64/lowering.zig`) lowers `MirOpcode.kynx_lease_check` into a direct call to the `kynx_check_lease` symbol:

```zig
.kynx_lease_check => {
    try block.instructions.append(self.allocator, .{
        .opcode = @intFromEnum(X86Opcode.call),
        .op1 = .{ .symbol = "kynx_check_lease" },
    });
},
```

(`MirOpcode.kynx_lease_end` lowers the same way to the `kynx_end_lease` symbol.)

---

## C Runtime Interface

```c
// Core Management API
void orbit_kynx_init(OrbitKynxConfig config);   // config: pool_size, rate_limit, window_ms,
                                                // ban_threshold, score_increment, score_decay, enabled
void orbit_kynx_cleanup(void);
void orbit_kynx_reset(void);

// Admission
bool orbit_kynx_check(const char* ip_str);

// Lease API
OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
bool            orbit_kynx_lease_check_limits(size_t additional_response_bytes);
void            orbit_kynx_lease_destroy(OrbitKynxLease* lease);

// State Inspection
bool     orbit_kynx_is_siege_mode(void);
uint64_t orbit_kynx_get_total_checks(void);
uint64_t orbit_kynx_get_total_blocked(void);
```

> Note: the native backend currently lowers `kynx_check_lease` / `kynx_end_lease` symbols; the runtime lease lifecycle functions consumed by the C backend are the `orbit_kynx_lease_*` entry points above.
