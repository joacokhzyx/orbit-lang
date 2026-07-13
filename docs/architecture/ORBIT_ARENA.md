# Orbit Arena Memory Architecture (Epochal Virtual Memory Engine)

This document describes the design, implementation, and performance characteristics of the Orbit Arena memory engine.

## 1. Problem with the Previous Arena
The previous implementation of `OrbitArena` utilized a chained block allocator:
* **Heap Contention:** Growing the arena required invoking `malloc()` in the hot allocation path, causing significant synchronization and allocation overhead under load.
* **Non-O(1) Reset:** Reseting the arena required traversing all allocated blocks in a linked list, making `orbit_arena_reset` complexity proportional to the number of blocks/allocations ($O(N)$).
* **Alignment Fragility:** All allocations were aligned to 16 bytes, but the payload began after `sizeof(OrbitArenaBlock)`, whose size did not preserve 16-byte alignment, leading to unaligned structures.
* **Global String Pool Contention & Dangling Pointers:** The string pool was global and fixed-capacity. Interning strings within an arena request cycle left dangling pointers to freed arenas after a reset occurred.
* **Data Races in Metrics:** Global performance metrics were mutated concurrently without atomic operations.

---

## 2. Architecture & Design Goals
The new memory engine introduces a **Virtual Memory (VM)** backend with an **Epochal lifecycle**.
* **Zero Allocations in Hot Path:** All normal allocations are bump-allocated from pre-reserved virtual address space. Physical memory pages are committed on-demand in page-sized increments.
* **Logical O(1) Reset:** Resetting an arena simply resets the bump cursor back to the base address and increments the epoch generation number. Old virtual memory segments are retained (up to a configurable retention window) or discarded.
* **Guaranteed Alignment:** Allocations start directly at `base` (aligned to page boundaries by the OS) and are bumped using safe checked calculations.
* **Generation-Aware Local String Pool:** Each arena holds its own string pool, which is reset in $O(1)$ when the arena is reset, eliminating data races and use-after-reset dangling pointers.
* **Atomic Telemetry & Thread-Safety:** All pool operations and global counters are managed with thread-safe atomic operations (`Interlocked` APIs on Windows and GCC/Clang builtins on POSIX).

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
* **Per-Arena Interning:** The string pool is localized inside the `OrbitArena` struct.
* **Zero Lock Contention:** Since each thread has its own arena (acquired from the pool), interning is lock-free.
* **Epoch-Safe:** Resetting the arena resets the string pool count to 0 in $O(1)$, naturally invalidating old strings.

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

## 9. How to Execute Tests & Benchmarks
### Run Correctness Suite
To compile and run all correctness unit tests (including the 25 correctness assertions for memory virtual backend, checkpoints, alignments, and pools):
```powershell
zig test src/tests.zig
# Or:
zig build test
```

### Run Performance Benchmarks
To run the high-speed benchmark comparing different memory allocation patterns:
```powershell
zig cc -O3 -Isrc/runtime src/runtime/benchmark_arena.c -o benchmark_arena.exe -lws2_32
.\benchmark_arena.exe
```
