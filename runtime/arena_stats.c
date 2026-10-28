#ifndef ORBIT_RT_ARENA_STATS_C
#define ORBIT_RT_ARENA_STATS_C

/* Telemetry accessors. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

/* ── Diagnostics ────────────────────────────────────────────────────── */

/** @brief Return the total number of bytes currently used across the active segment and all overflow segments. */
size_t orbit_arena_used(const OrbitArena* arena) {
    if (!arena) return 0;
    size_t total_used = (size_t)(arena->cursor - arena->base);
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        total_used += overflow->size; /* Each retired segment is counted in full. */
        overflow = overflow->next;
    }
    return total_used;
}

/** @brief Return the total reserved virtual address space, in bytes. */
size_t orbit_arena_capacity(const OrbitArena* arena) {
    return arena ? arena->reserved_bytes : 0;
}

/** @brief Return the cumulative allocation count since the last reset. */
uint64_t orbit_arena_alloc_count(const OrbitArena* arena) {
    return arena ? arena->alloc_count : 0;
}

/** @brief Return the high-water mark of used bytes since creation/reset. */
size_t orbit_arena_peak_used(const OrbitArena* arena) {
    return arena ? arena->peak_used : 0;
}

/** @brief Bytes this arena is using in its active segment right now.
 *
 *  At the end of a request this is that request's footprint: the bump cursor
 *  only moves forward within a request (rewind is not used on the request
 *  path), so the value at exit is the request's high-water mark. After an
 *  overflow the arena has moved to a fresh segment and this counts the new
 *  segment only, which is why the per-route row reports orbit_arena_overflowed
 *  beside it. */
size_t orbit_arena_active_bytes(const OrbitArena* arena) {
    return arena ? arena->used : 0;
}

/** @brief Non-zero when this arena chained an overflow segment since its last reset. */
int orbit_arena_overflowed(const OrbitArena* arena) {
    return (arena && arena->overflow_list != NULL) ? 1 : 0;
}

#endif
