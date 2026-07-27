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
                 ┌──────────────────────┼──────────────────────┐
                 │                      │                      │
                 ▼                      ▼                      ▼
         [Suspicion <= 10]     [10 < Suspicion <= 50]   [Suspicion > 50]
           State: STABLE          State: SHAPED           State: SIEGE
                 │                      │                      │
                 ▼                      ▼                      ▼
          Standard Budget        Strict Memory Lease     Immediate Drop
        (64MB Arena, 50ms)       (16MB Arena, 10ms)       (O(1) Rejection)
```

---

## State Machine & Admission Control

Kynx computes admission states dynamically using a sliding-window suspicion scoring algorithm over sharded IP buckets.

### Admission States

| State | Suspicion Score Range | Arena Memory Cap | Execution Deadline | HTTP Response Action |
| :--- | :--- | :--- | :--- | :--- |
| `STABLE` | $0 \le S \le 10$ | 64 MB | 50.0 ms | `200 OK` (Standard processing) |
| `SHAPED` | $11 \le S \le 30$ | 32 MB | 25.0 ms | `200 OK` (Throttled burst) |
| `GUARDED` | $31 \le S \le 50$ | 16 MB | 10.0 ms | `429 Too Many Requests` |
| `SIEGE` | $S > 50$ | 0 MB | 0.0 ms | `503 Service Unavailable` |

### O(1) Shard Lookup

IP tracking uses fixed-capacity hash table shards with Atomic Spinlocks (`orbit_kynx_lock`) to prevent thread contention during peak throughput.

```c
typedef struct {
    uint8_t family; // AF_INET (4) or AF_INET6 (16)
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
} OrbitKynxIPEntry;
```

---

## Computational Leases

A **Computational Lease** (`OrbitKynxLease`) defines the strict resource boundary assigned to a single thread execution context.

```c
typedef struct {
    uint64_t lease_id;
    uint64_t deadline_ns;
    size_t   max_arena_bytes;
    size_t   max_db_queries;
    size_t   current_db_queries;
    bool     revoked;
} OrbitKynxLease;
```

### Lifetime Lifecycle

1. **Lease Acquisition (`kynx_lease_check`)**:
   Emitted by the backend compiler at the entry block of every route handler. If admission state is `SIEGE`, execution halts immediately.

2. **Instruction-Boundary Verification**:
   The compiler backend injects lowering checks (`.kynx_lease_check`) inside loop back-edges and recursive function calls:
   ```assembly
   call kynx_check_lease
   test rax, rax
   jnz .Llease_valid
   mov rsp, rbp
   pop rbp
   ret
   .Llease_valid:
   ```

3. **Lease Revocation & Cleanup (`kynx_lease_end`)**:
   Upon handler completion, `kynx_lease_end` decrements active lease counters and resets the local request arena in $O(1)$.

---

## Compiler Lowering Integration

The x86-64 backend (`src/backend/x86_64/lowering.zig`) lowers `MirOpcode.kynx_lease_check` into a direct system ABI call:

```zig
.kynx_lease_check => {
    const fn_sym = LirRegister{
        .id = @intFromEnum(RegisterId.rax),
        .is_physical = true,
    };
    try self.emitMovSymbol(block, fn_sym, "kynx_check_lease");
    try block.instructions.append(self.allocator, .{
        .opcode = @intFromEnum(X86Opcode.call),
        .op1 = .{ .reg = fn_sym },
    });
},
```

---

## C Runtime Interface

```c
// Core Management API
void orbit_kynx_init(const OrbitKynxConfig* config);
void orbit_kynx_shutdown(void);

// Lease API
OrbitKynxLease* kynx_begin_lease(const char* ip_str);
bool            kynx_check_lease(OrbitKynxLease* lease);
void            kynx_end_lease(OrbitKynxLease* lease);

// State Inspection
int  orbit_kynx_get_state(void);
void orbit_kynx_reset_metrics(void);
```
