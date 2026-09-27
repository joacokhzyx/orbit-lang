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

Each arena maintains an optional per-arena string interning table (`OrbitStringPoolLocal`). Strings allocated inside the arena are deduplicated via FNV-1a hash lookups.

```c
typedef struct OrbitStringNode {
    uint64_t hash;
    const char* str;
    size_t len;
    struct OrbitStringNode* next;
} OrbitStringNode;
```

When `orbit_arena_reset` is called, the interning table hash buckets are cleared in $O(1)$ without freeing individual nodes.

---

## Arena Pooling & Thread Caching

To eliminate the cost of repeated OS allocation calls for short-lived tasks (such as HTTP request handlers), Orbit implements a global, concurrency-safe arena pool (`runtime/arena_pool.c`).

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
2. **Acquire**: `orbit_arena_pool_acquire()` returns a free arena (reset before use) in $O(1)$; if the pool is exhausted it returns a temporary overflow arena.
3. **Release**: `orbit_arena_pool_release(arena)` resets the arena (retaining up to 256 KB of hot committed memory) and returns it to the pool.

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
