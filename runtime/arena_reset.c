#ifndef ORBIT_RT_ARENA_RESET_C
#define ORBIT_RT_ARENA_RESET_C

/* Reset: O(1) logical cleanup and the decommit policy. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

/* ── Reset (O(1) logical cleanup & decommit reclamation policy) ─────── */

/** @brief Reset @p arena to its initial state in O(1): release overflow segments, decommit excess pages, and bump the generation counter. */
void orbit_arena_reset(OrbitArena* arena) {
    if (!arena) return;

    orbit_perf_record_reset();

    /* Step 1: release all chained overflow (retired) segments. */
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        OrbitArenaOverflow* next = overflow->next;
        orbit_virtual_release(overflow->ptr, overflow->size);
        free(overflow);
        overflow = next;
    }
    arena->overflow_list = NULL;

    /* Step 2: decommit pages beyond the hot-retention watermark.
     *
     * The watermark is this arena's live footprint -- the pages the request just
     * touched -- clamped to [floor, ceiling] and to the active reservation,
     * rather than the fixed floor alone. A request that grew past the floor keeps
     * its pages for the next request on this worker instead of paying one
     * decommit plus a re-commit of the whole footprint every time. Below the
     * floor the policy is exactly what it was, so a service whose requests fit in
     * 256 KB sees the same reset it saw before, and the ceiling bounds the
     * resident set at workers * ORBIT_ARENA_HOT_RETENTION_CEILING. The cursor is
     * still on the previous request's end here (Step 3 rewinds it), and after an
     * overflow it points into the segment the arena last allocated from, so the
     * measurement is the live segment only. */
    size_t page_size = arena->page_size;
    size_t used_bytes = (size_t)(arena->cursor - arena->base);
    size_t keep_size = ORBIT_ARENA_HOT_RETENTION_LIMIT;
    if (used_bytes > keep_size) {
        keep_size = used_bytes;
    }
    if (keep_size > ORBIT_ARENA_HOT_RETENTION_CEILING) {
        keep_size = ORBIT_ARENA_HOT_RETENTION_CEILING;
    }
    keep_size = orbit_align_up(keep_size, page_size);

    size_t total_reserved = (size_t)(arena->reserved_end - arena->base);
    if (keep_size > total_reserved) {
        keep_size = total_reserved;
    }

    unsigned char* keep_end = arena->base + keep_size;
    if (arena->committed_end > keep_end) {
        size_t decommit_size = (size_t)(arena->committed_end - keep_end);
        orbit_virtual_decommit(keep_end, decommit_size);
        orbit_perf_record_decommit_op();
        arena->committed_end = keep_end;
    }

    arena->committed_bytes = (size_t)(arena->committed_end - arena->base);
    arena->reserved_bytes  = total_reserved;

    /* Step 3: rewind the bump pointer and advance the epoch generation.
     *
     * The join happens here, before the interval counters are cleared: this is
     * the only place the process totals learn about arena allocations, so
     * they are exact (atomic adds, nothing lost) and cost four RMWs per
     * request rather than four stores per allocation at each bump. */
    orbit_perf_fold_arena(arena->alloc_count, arena->requested_bytes,
                          arena->aligned_bytes, arena->peak_used);

    arena->cursor         = arena->base;
    arena->requested_bytes = 0;
    arena->aligned_bytes  = 0;
    arena->alloc_count    = 0;
    arena->generation++;

    /* Synchronise compatibility alias fields. */
    arena->used     = 0;
    arena->capacity = total_reserved;
    arena->buffer   = (char*)arena->base;

    /* Step 4: invalidate the per-arena interning table. */
    if (arena->local_string_pool) {
        orbit_string_pool_local_reset(arena->local_string_pool);
    }
}

#endif
