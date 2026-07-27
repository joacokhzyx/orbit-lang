# Arena

Arena is the epoch-based virtual-memory allocator for the Orbit runtime. It implements a region-based memory model backed directly by OS virtual memory primitives (`VirtualAlloc` on Windows, `mmap` on POSIX).

Arena eliminates garbage collection pauses, pointer tracing overhead, and heap fragmentation by enforcing $O(1)$ allocation and $O(1)$ region reset.

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

### Struct Layout (`src/runtime/arena.c`)

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

If $\text{new\_cursor} \le \text{committed\_end}$, allocation completes in **3 CPU instructions**.

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

To eliminate the cost of repeated OS allocation calls for short-lived tasks (such as HTTP request handlers), Orbit implements thread-local Arena pooling (`src/runtime/arena_pool.c`).

```c
typedef struct {
    OrbitArena* pool[16];
    int count;
} OrbitArenaThreadCache;
```

1. **Acquire**: `orbit_arena_acquire()` retrieves a pre-reserved arena from the thread-local pool in $O(1)$.
2. **Release**: `orbit_arena_release(arena)` resets the cursor, retains up to 256 KB of committed physical memory, and returns the arena to the pool.

---

## Performance & Complexity Invariants

| Operation | Time Complexity | Space Overhead | OS Traps |
| :--- | :--- | :--- | :--- |
| `orbit_alloc(size)` (Fast Path) | $O(1)$ | 0 bytes | 0 |
| `orbit_alloc(size)` (Commit Path) | $O(1)$ amortized | 0 bytes | 1 (`VirtualAlloc` / `mmap`) |
| `orbit_arena_reset(arena)` | $O(1)$ | 0 bytes | 0 (retains hot pages) |
| `orbit_arena_destroy(arena)` | $O(1)$ | 0 bytes | 1 (`VirtualFree` / `munmap`) |

### Garbage Collection Comparison

- **Tracing GC (Go, V8)**: Scans live object graph ($O(N)$ where $N$ = live objects). Introduces latency spikes.
- **Borrow Checker (Rust)**: Move semantics and lifetime annotations enforced at compile time.
- **Orbit Arena**: Region lifetime tied to task scope. Zero compile-time lifetime annotations, zero runtime GC pauses.
