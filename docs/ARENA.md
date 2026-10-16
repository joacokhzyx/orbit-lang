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

If an allocation exceeds the 64 MB virtual reservation limit, Arena allocates a dedicated OS memory block and chains it to `overflow_list` to prevent out-of-memory crashes.

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

A lookup compares lengths first and then `memcmp`s, so it is $O(n)$ in the number of strings already interned in this epoch - `runtime/string_pool.c` says as much at the top ("Lookups are O(n) over the pool"). A miss allocates the canonical copy with `orbit_alloc` and appends it. `orbit_arena_reset` clears the table in $O(1)$ by setting `count = 0`; the arrays themselves live until `orbit_arena_destroy` frees them (`runtime/arena.c:258`).

FNV-1a hashing and open-addressed buckets do exist in this runtime, but for `Map<K,V>`, not for string interning: `runtime/collections.c` (`OrbitMapEntry`, 75 % load factor, buckets abandoned in the arena and reclaimed on reset). Do not read that machinery into this table.

`orbit_string_pool_init(capacity)` and `orbit_string_pool_cleanup()` are compatibility stubs that ignore their argument; the generated server calls both (`compiler/route_runtime.orb:567`, `:732`) and they do nothing.

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
3. **Release**: `orbit_arena_pool_release(arena)` resets the arena (retaining up to 256 KB of hot committed memory) and returns it to the pool.

### The pool is not the request path

The pool serves process **startup** work, not requests. The generated server initializes it and immediately acquires one arena for startup scratch work (`compiler/route_runtime.orb:566`, `:585-587`); after that it sits idle until `orbit_arena_pool_cleanup` at shutdown (`:731`). Nothing else in the tree acquires from it, and that is the whole caller list.

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
before every `orbit_handle_request` (`compiler/route_runtime.orb:453`).
`orbit_arena_checkpoint` and `orbit_arena_rewind` both exist
(`runtime/arena.c:582,592`) and a rewind *is* an $O(1)$ bump-pointer
restore, but nothing in the tree calls them outside `arena.c` itself
and `runtime/test_arena.c`. I grepped for it. So
`arena_checkpoint_count` and `arena_rewind_count` in
`runtime/performance.h` are always zero in a running server, and
`orbit_arena_reset` is not the $O(1)$ rewind the table above could
imply: it releases the chained overflow segments and decommits every
page past the hot retention watermark
(`runtime/arena.c:526`). Treat the checkpoint API as available to
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
| `orbit_alloc(size)` (Commit Path) | $O(1)$ amortized | 0 bytes | 1 (`VirtualAlloc` / `mmap`) |
| `orbit_arena_reset(arena)` | $O(1)$ | 0 bytes | 0 (retains hot pages) |
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
`ORBIT_ARENA_HOT_RETENTION_LIMIT` (256 KB kept hot after reset).

**Telemetry** (`runtime/performance.h`): `arena_alloc_count`,
`arena_requested_bytes`, `arena_aligned_bytes`,
`arena_virtual_reserved_bytes`, `arena_committed_bytes`,
`arena_peak_used_bytes`, `arena_resets`, `arena_overflow_allocations`,
`arena_checkpoint_count`, `arena_rewind_count` (the last two are always
zero in a running server — see above).

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
