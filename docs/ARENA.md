# Arena

Arena is the epoch-based virtual-memory allocator for the Orbit runtime. It uses a region-based model backed directly by OS virtual memory (`VirtualAlloc` on Windows, `mmap` on POSIX).

Arena tries to avoid garbage-collection pauses, pointer tracing, and heap fragmentation for request-scoped work by allocating with a bump pointer and resetting the whole region at once. The complexity targets below are design goals - I treat them as claims that need measurement on your hardware, not guarantees.

---

## Memory Layout & Virtual Reservation

Each `OrbitArena` instance pre-reserves a contiguous 64 MB Virtual Address (VA) space upon creation. Physical memory pages are committed dynamically in 64 KB growth increments as the allocation cursor advances.

```
+───────────────────────────────────────────────────────────────────────────+
│                           Reserved VA Space (64 MB)                       │
+─────────────────────────────────────┬─────────────────────────────────────+
│      Committed Memory Pages         │        Uncommitted VA Space         │
+──────────────────┬──────────────────┼─────────────────────────────────────+
│ Allocated Data   │ Available Margin │          Unmapped OS Pages          │
│ (cursor)         │ (committed_end)  │          (reserved_end)            │
+──────────────────┴──────────────────┴─────────────────────────────────────+
```

### Struct Layout (`runtime/arena.c`)

```c
typedef struct OrbitArena {
    unsigned char* base;
    unsigned char* cursor;
    unsigned char* committed_end;
    unsigned char* reserved_end;

    size_t page_size;
    size_t requested_bytes;
    size_t aligned_bytes;
    size_t peak_used;
    size_t committed_bytes;
    size_t reserved_bytes;

    uint64_t generation;
    uint64_t alloc_count;

    struct OrbitArena* parent;
    struct OrbitStringPoolLocal* local_string_pool;
    OrbitArenaOverflow* overflow_list;
} OrbitArena;
```

---

## Allocation Mechanics

### 1. Pointer Bump Allocation ($O(1)$ Fast Path)

When requesting memory of size $N$, the allocator rounds $N$ to the default 16-byte alignment boundary (`ORBIT_ARENA_ALIGN`) and advances the bump cursor:

$$\text{new\_cursor} = \text{align\_up}(\text{cursor} + N, 16)$$

If $\text{new\_cursor} \le \text{committed\_end}$, allocation completes on the fast path without OS traps. The exact instruction count depends on toolchain and CPU - measure on your target rather than trusting a fixed number.

### 2. Page Commit Path

If $\text{new\_cursor} > \text{committed\_end}$, Arena invokes the OS virtual memory layer to commit physical pages up to the next growth granularity (64 KB):

```c
#ifdef _WIN32
    VirtualAlloc(arena->committed_end, commit_size, MEM_COMMIT, PAGE_READWRITE);
#else
    mprotect(arena->committed_end, commit_size, PROT_READ | PROT_WRITE);
#endif
```

### 3. Overflow List Chaining

If an allocation would land past the 64 MB virtual reservation, Arena allocates a dedicated OS memory block and chains it to `overflow_list` rather than failing the request, and a chained segment is what `arena_overflow` (and D032) counts.

Two things bound when that can happen. The allocation path charges the Kynx lease first (`runtime/arena.c:340`), and the default lease caps a request's arena at **16 MB cumulative** (`runtime/kynx.c:990`); the admission states tighten that figure and none raises it. A request that is admitted therefore cannot walk the cursor past a 64 MB reservation, so under the default policy the chain is unreachable. Measured on `exp/harena`: the first request that needed 16 MB in one allocation was refused with `orbit: out of memory allocating 16777217 bytes`, and nothing chained. Where the lease does not bind -- `ORBIT_KYNX=0`, or a budget above the reservation -- one request does chain and the column is non-zero, which is how the end-to-end positive was produced (report section 4).

---

## String Pool & Interning

Each arena maintains an optional per-arena string interning table (`OrbitStringPoolLocal`), created lazily on the first intern. It deduplicates the strings one arena epoch makes, but **not** with a hash: the table is two flat `malloc`'d arrays (pointer and length per entry) that the lookup walks linearly.

```c
typedef struct OrbitStringPoolLocal {
    const char** strings;
    size_t*      lengths;
    int          count;
    int          capacity;   /* 4096, doubled when full */
} OrbitStringPoolLocal;
```

A lookup compares lengths first and then `memcmp`s, so it is $O(n)$ in the number of strings already interned in this epoch - `runtime/string_pool.c` says as much at the top ("Lookups are O(n) over the pool"). A miss allocates the canonical copy with `orbit_alloc` and appends it. `orbit_arena_reset` clears the table in $O(1)$ by setting `count = 0`; the arrays themselves live until `orbit_arena_destroy` frees them (`runtime/arena.c:265`).

FNV-1a hashing and open-addressed buckets do exist in this runtime, but for `Map<K,V>`, not for string interning: `runtime/collections.c` (`OrbitMapEntry`, 75 % load factor, buckets abandoned in the arena and reclaimed on reset). Do not read that machinery into this table.

`orbit_string_pool_init(capacity)` and `orbit_string_pool_cleanup()` are compatibility stubs that ignore their argument; the generated server calls both (`compiler/emit/route_runtime.orb:567`, `:732`) and they do nothing.

---

## Arena Pooling & Thread Caching

`runtime/arena_pool.c` holds a global, concurrency-safe pool of pre-created arenas.

```c
typedef struct {
    OrbitArena** arenas;
    volatile int* in_use;
    int          pool_size;
    size_t       arena_capacity;
    volatile int active_count;     /* atomic */
    uint64_t     total_acquires;   /* atomic */
    uint64_t     overflow_creates; /* atomic */
} OrbitArenaPool;
```

1. **Init**: `orbit_arena_pool_init(pool_size, arena_capacity)` pre-creates `pool_size` arenas.
2. **Acquire**: `orbit_arena_pool_acquire()` returns a free arena (reset before use) in $O(1)$; if the pool is exhausted it creates a temporary arena (`orbit_arena_create`) and counts it as an overflow.
3. **Release**: `orbit_arena_pool_release(arena)` resets the arena (retaining the footprint it just used, never below 256 KB and never above `ORBIT_ARENA_HOT_RETENTION_CEILING`) and returns it to the pool.

### The pool is not the request path

The pool serves process **startup** work, not requests. The generated server initializes it and immediately acquires one arena for startup scratch work (`compiler/emit/route_runtime.orb:566`, `:585-587`); after that it sits idle until `orbit_arena_pool_cleanup` at shutdown (`:731`). Nothing else in the tree acquires from it, and that is the whole caller list.

The request path is one private arena per worker thread instead. `orbit_worker_loop` creates a 128 KB arena when the thread starts - the emitted comment is "Each thread owns its private arena - zero pool contention" (`:368-369`) - resets it before every `orbit_handle_request` (`:485`), and destroys it when the loop ends (`:521`). That is deliberate: a per-thread arena needs no lock to acquire, and the reset cost lands on the thread that caused it.

So the mechanism that serves requests is `orbit_arena_create` + `orbit_arena_reset` on the worker's own arena, not the pool. Treat the pool as available infrastructure (hand-written C can acquire from it), in the same spirit as `orbit_arena_checkpoint`/`rewind`: real, usable, and outside the generated server's request path.

---

## What "epoch" means in practice, and what `lib/arena.orb` is not

Two claims get conflated, so here they are separated.

**The C runtime arena is a real allocator.** Everything above is
about `runtime/arena.c`, and it does allocate dereferenceable memory
by bump pointer. The word "allocator" is correct for it.

**The request boundary is a whole-arena reset, not a checkpoint.**
The generated connection loop calls `orbit_arena_reset(thread_arena)`
before every `orbit_handle_request` (`compiler/emit/route_runtime.orb:453`).
`orbit_arena_checkpoint` and `orbit_arena_rewind` both exist
(`runtime/arena.c:565,575`) and a rewind *is* an $O(1)$ bump-pointer
restore, but nothing in the tree calls them outside `arena.c` itself
and `runtime/test_arena.c`. I grepped for it. So
`arena_checkpoint_count` and `arena_rewind_count` in
`runtime/performance.h` are always zero in a running server, and
`orbit_arena_reset` is not the $O(1)$ rewind the table above could
imply: it releases the chained overflow segments and decommits every
page past the hot retention watermark -- which is the footprint the
request just used, clamped to [256 KB,
`ORBIT_ARENA_HOT_RETENTION_CEILING`]
(`runtime/arena.c:515`). Treat the checkpoint API as available to
hand-written C, not as the mechanism serving requests.

**`lib/arena.orb` is neither.** It is not an allocator and does not
pretend to be one any more. There is no pointer arithmetic in Orbit
and no `mmap`/`VirtualAlloc` binding, so its `buffer` is a string that
is never read and its `alloc` returns an **offset into a logical
region, not an address**. Nothing you get back is dereferenceable.
What the module actually provides is a bound — `alloc` returns -1
rather than growing past `capacity` — and the $O(1)$ reset. That is
all it claims, and this page should agree with the comment at the top
of that file rather than with the word "allocator".

---

## Performance & Complexity Invariants

| Operation | Time Complexity | Space Overhead | OS Traps |
| :--- | :--- | :--- | :--- |
| `orbit_alloc(size)` (Fast Path) | $O(1)$ | 0 bytes | 0 |
| `orbit_alloc(size)` (Commit Path) | $O(1)$ amortized | 0 bytes | 1 (`VirtualAlloc` / `mprotect`) |
| `orbit_arena_reset(arena)` | $O(1)$ | 0 bytes | 1 when committed pages exceed the retained watermark, else 0 |
| `orbit_arena_destroy(arena)` | $O(1)$ | 0 bytes | 1 (`VirtualFree` / `munmap`) |

### Garbage Collection Comparison

Different tradeoffs, not a ranking:

- **Tracing GC (Go, V8)**: scans live objects. Flexible for general heaps, can introduce pauses under pressure.
- **Borrow Checker (Rust)**: checks lifetimes at compile time. Precise, with more annotations to write.
- **Orbit Arena**: ties lifetime to task scope (one request = one region). No per-object tracking and no compile-time lifetime annotations for this pattern, but it's only a good fit when work really is request-scoped. If you hold data across requests, you need a different strategy.

---

## Appendix: design history and testing

This used to be `docs/architecture/ORBIT_ARENA.md`, folded here so the
allocator is described once. What that file added over this page:

**Why the previous arena was replaced.** Chained-block allocator with
`malloc()` in the hot path (heap contention), $O(N)$ reset by block-list
traversal, 16-byte alignment broken by the block header size, a global
fixed-capacity string pool that left dangling pointers after reset, and
non-atomic global metrics. The current design answers each of those;
measure, don't assume.

**Configuration** (macros in `runtime/arena.c`): `ORBIT_ARENA_ALIGN` (16),
`ORBIT_ARENA_DEFAULT_RESERVE` (64 MB), `ORBIT_ARENA_DEFAULT_COMMIT`
(64 KB), `ORBIT_ARENA_GROWTH_GRANULARITY` (64 KB),
`ORBIT_ARENA_HOT_RETENTION_LIMIT` (256 KB floor kept hot after reset),
`ORBIT_ARENA_HOT_RETENTION_CEILING` (4 MB ceiling on that retention).

**Telemetry** (`runtime/performance.h`): `arena_alloc_count`,
`arena_requested_bytes`, `arena_aligned_bytes`,
`arena_virtual_reserved_bytes`, `arena_committed_bytes`,
`arena_peak_used_bytes`, `arena_resets`, `arena_overflow_allocations`,
`arena_checkpoint_count`, `arena_rewind_count` (the last two are always
zero in a running server — see above).

The allocation counters are **private to one arena** and joined into the
process totals once per request, by `orbit_arena_reset`. The allocation fast
path writes no global at all: a store per allocation on a line every worker
shares was the cost being removed, and the join is six RMWs per request instead
(one increment for `arena_resets`, four adds, one compare-and-swap for the
peak). The join is also exact, because an atomic add cannot lose an update
where the plain per-allocation stores could, and because an arena is reset by
the worker that owns it. `orbit_arena_destroy` folds the final interval of an
arena that will never be reset again (worker shutdown, a child arena, the
pool).

What this deliberately does **not** count: an arena that is neither reset nor
destroyed. In practice that is the process-wide fallback arena
(`orbit_arena_get_global`), which lives for the life of the process. Nothing on
the request path allocates from it -- measured on `exp/harena`, its counters stay
at zero while a route's string work runs, because the runtime's allocation
helpers keep the arena they are handed -- so this is a gap in the *set* of
arenas, not a loss of request bytes. A hand-written C program that allocates only
from the global arena sees the four counters stay at zero.

What the join does change is *when* the totals publish. It happens at
`orbit_arena_reset`, which the emitted loop calls before each request, and each
worker owns its arena (eight on the measurement box), so a worker's last interval
is published by *that worker's* next request and not by a request that lands on
another worker. Under continuous traffic that is one request per worker; a worker
that stops taking requests holds its interval until its next request or until
`orbit_arena_destroy` folds it at shutdown. `/_ledger`'s per-route columns are not
deferred: they are written in the request that measures them.

`runtime/test_arena_telemetry.c` is the gate: four threads' arenas against the
aggregate delta, the fast path proved to publish nothing, and the per-route
memory columns.

**Running the arena tests.** The invariants live in one C test program
CI runs on every push (`runtime/test_arena.c`):

```sh
# POSIX
cc -O0 -w -I runtime -DORBIT_WITH_NET runtime/test_arena.c -o t_arena_bin
./t_arena_bin

# Windows (add the Winsock import library)
cc -O0 -w -I runtime -DORBIT_WITH_NET runtime/test_arena.c -o t_arena_bin.exe -lws2_32
.\t_arena_bin.exe
```

Exit status 0 means every assertion held; one line per invariant.
