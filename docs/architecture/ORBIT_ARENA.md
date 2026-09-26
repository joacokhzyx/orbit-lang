# Orbit Arena Memory Architecture

This document describes the design and implementation of the Orbit Arena allocator. It's the allocator behind request-scoped memory: one request, one region, reclaimed together.

## 1. Problem with the Previous Arena
The previous implementation of `OrbitArena` utilized a chained block allocator:
* **Heap Contention:** Growing the arena required invoking `malloc()` in the hot allocation path, causing significant synchronization and allocation overhead under load.
* **Non-O(1) Reset:** Reseting the arena required traversing all allocated blocks in a linked list, making `orbit_arena_reset` complexity proportional to the number of blocks/allocations ($O(N)$).
* **Alignment Fragility:** All allocations were aligned to 16 bytes, but the payload began after `sizeof(OrbitArenaBlock)`, whose size did not preserve 16-byte alignment, leading to unaligned structures.
* **Global String Pool Contention & Dangling Pointers:** The string pool was global and fixed-capacity. Interning strings within an arena request cycle left dangling pointers to freed arenas after a reset occurred.
* **Data Races in Metrics:** Global performance metrics were mutated concurrently without atomic operations.

---

## 2. Architecture & Design Goals
The current design uses a **Virtual Memory (VM)** backend with an **epoch lifecycle**.
* **No allocations in the hot path (goal):** normal allocations bump from pre-reserved address space. Pages commit on demand. Treat as target to measure, not guarantee.
* **Fast reset (goal):** resetting moves the bump cursor back and bumps the epoch. Old segments are kept briefly or released. Measure on your target.
* **Alignment by construction:** allocations start at `base` (page-aligned by the OS) and advance with checked math.
* **Local string pool per arena:** each arena holds its own pool, cleared on reset. This avoids cross-request sharing bugs when used as documented.
* **Atomic telemetry:** pool counters use atomics (`Interlocked` on Windows, builtins on POSIX).

---

## 3. Architecture of Reserve / Commit
Memory allocation is split into two phases:
1. **Virtual Reservation:** The OS reserves a large, contiguous range of virtual address space (default `64 MB`). No physical memory or page table structures are mapped at this stage.
2. **Physical Commit:** Physical pages are committed in blocks of `64 KB` (default `ORBIT_ARENA_GROWTH_GRANULARITY`) when the cursor crosses the current committed boundary.

```
+--------------------------------------------------------------------------------+
|  Committed (Physical Memory)     |  Reserved (Virtual Address Space only)      |
+------------------------------------+-------------------------------------------+
^                                    ^                                           ^
base                                 committed_end                               reserved_end
```

### Path Execution
* **Fast Path:** `cursor + aligned_size <= committed_end`. Simply returns `cursor` and advances it.
* **Slow Path:** `cursor + aligned_size <= reserved_end`. Calls `orbit_virtual_commit` to map more physical pages up to the next page boundary, advances `committed_end`, and returns the allocation.
* **Exception/Overflow Path:** The reservation is fully exhausted. A new virtual memory segment is reserved and committed. The old segment is saved in `overflow_list` to maintain pointer stability.

---

## 4. Reset & Decommit Reclamation Policy
When `orbit_arena_reset` is called:
1. Any overflow segments allocated during the epoch are released back to the OS.
2. The current active segment's cursor is reset to `base`.
3. If committed pages exceed `ORBIT_ARENA_HOT_RETENTION_LIMIT` (default `256 KB`), the excess pages are decommitted (`MEM_DECOMMIT` / `MADV_DONTNEED`) to release physical RAM. Pages below the limit are kept committed to avoid page faults on subsequent requests.
4. The generation number is incremented.

---

## 5. Checkpoints & Rewind
For allocations with a lifetime shorter than the request, checkpoints are supported:
* `OrbitArenaCheckpoint cp = orbit_arena_checkpoint(arena);`
* `orbit_arena_rewind(arena, cp);`

**Safety Invariants:**
* Checks `checkpoint.generation == arena->generation` to prevent rewinding after a reset.
* Prevents advancing the cursor forward (`checkpoint.offset <= current_offset`).

---

## 6. String Interning & Concurrency
* **Per-arena interning:** the pool lives inside `OrbitArena`.
* **Low contention by design:** each thread borrows its own arena from the pool, so interning usually needs no locks. It isn't lock-free by magic - measure under your concurrency.
* **Epoch-safe use:** resetting clears the pool count. Don't hold pointers across resets.

---

## 7. Configuration Constants
Configurable macros in `arena.c`:
* `ORBIT_ARENA_ALIGN`: Default `16` bytes.
* `ORBIT_ARENA_DEFAULT_RESERVE`: Default `64 MB` virtual reservation.
* `ORBIT_ARENA_DEFAULT_COMMIT`: Default `64 KB` initial physical commit.
* `ORBIT_ARENA_GROWTH_GRANULARITY`: Default `64 KB` increments.
* `ORBIT_ARENA_HOT_RETENTION_LIMIT`: Default `256 KB` kept hot after reset.

---

## 8. Telemetry Metrics
Instrumented metrics in `performance.h`:
* `arena_alloc_count`: Total allocations made.
* `arena_requested_bytes`: Raw bytes requested.
* `arena_aligned_bytes`: Aligned bytes allocated.
* `arena_virtual_reserved_bytes`: Virtual space reserved.
* `arena_committed_bytes`: Physical memory committed.
* `arena_peak_used_bytes`: Peak committed memory used.
* `arena_resets`: Total resets performed.
* `arena_overflow_allocations`: Segment expansions triggered.
* `arena_checkpoint_count` & `arena_rewind_count`.

---

## 9. How to Run the Arena Tests

The arena invariants (virtual memory backend, checkpoints, alignment, pools,
cross-request isolation) live in one C test program that CI already runs on
every push. It is a single translation unit because the runtime is an
amalgamation-by-include: it gets `runtime/` on the include path and nothing
else.

```sh
# POSIX
cc -O0 -w -I runtime -DORBIT_WITH_NET runtime/test_arena.c -o t_arena_bin
./t_arena_bin

# Windows (add the Winsock import library)
cc -O0 -w -I runtime -DORBIT_WITH_NET runtime/test_arena.c -o t_arena_bin.exe -lws2_32
.\t_arena_bin.exe
```

Exit status 0 means every assertion held. The test prints one line per
invariant, so a failure names the invariant rather than only the offset.
