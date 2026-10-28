#ifndef ORBIT_RT_ARENA_C
#define ORBIT_RT_ARENA_C

/* Core of the arena: create and destroy. A program that only starts and ends
 * an arena links this member and none of the others (arena_alloc, arena_reset,
 * arena_checkpoint, arena_child, arena_stats, arena_oom, arena_global). */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

/* A decimal megabyte count from `name`, or `fallback` when the variable is
 * unset, empty, zero, negative, non-numeric or overflows. A malformed value is
 * not a new way for a process to fail to start. */
static size_t orbit_arena_megabytes_from_env(const char* name, size_t fallback) {
    const char* raw = orbit_env_get(name);
    if (!raw || raw[0] == '\0') return fallback;

    size_t mb = 0;
    for (const char* p = raw; *p; p++) {
        if (*p < '0' || *p > '9') return fallback;
        size_t digit = (size_t)(*p - '0');
        if (mb > ((size_t)-1 - digit) / 10) return fallback;
        mb = mb * 10 + digit;
    }
    if (mb == 0) return fallback;
    if (mb > ((size_t)-1) / (1024 * 1024)) return fallback;
    return mb * 1024 * 1024;
}

/* Total physical memory, or 0 when the platform will not say. The ceiling is
 * a fraction of it, so the number does not have to be guessed per machine. */
static size_t orbit_physical_memory_bytes(void) {
#ifdef _WIN32
    MEMORYSTATUSEX status;
    status.dwLength = sizeof(status);
    if (GlobalMemoryStatusEx(&status)) return (size_t)status.ullTotalPhys;
    return 0;
#else
    long pages = sysconf(_SC_PHYS_PAGES);
    long page = sysconf(_SC_PAGE_SIZE);
    if (pages <= 0 || page <= 0) return 0;
    return (size_t)pages * (size_t)page;
#endif
}

/* The default ceiling: three quarters of physical memory, which is the point
 * past which a process that keeps committing makes the machine swap. The
 * compiled value answers only when the platform will not report the total. */
static size_t orbit_arena_default_max(void) {
    size_t physical = orbit_physical_memory_bytes();
    if (physical == 0) return ORBIT_ARENA_DEFAULT_MAX;
    return physical - physical / 4;
}

/* The committed-bytes ceiling: ORBIT_ARENA_MAX_MB, or the default above. It
 * stops a runaway allocation before the machine swaps, which is how an
 * emitter that kept growing presented as a freeze rather than as an error. */
static size_t orbit_arena_max_rule_from_env(void) {
    size_t from_env = orbit_arena_megabytes_from_env("ORBIT_ARENA_MAX_MB", 0);
    return from_env != 0 ? from_env : orbit_arena_default_max();
}

/* ── Creation & Destruction ─────────────────────────────────────────── */

/** @brief Create a new root arena, reserving at least @p initial_capacity bytes of virtual address space. */
OrbitArena* orbit_arena_create(size_t initial_capacity) {
    size_t page_size = orbit_get_page_size();
    
    size_t reserve_size = ORBIT_ARENA_DEFAULT_RESERVE;
    if (initial_capacity > reserve_size) {
        reserve_size = initial_capacity;
    }
    reserve_size = orbit_align_up(reserve_size, page_size);
    if (reserve_size == 0) return NULL;
    
    size_t commit_size = initial_capacity > 0 ? initial_capacity : ORBIT_ARENA_DEFAULT_COMMIT;
    commit_size = orbit_align_up(commit_size, page_size);
    if (commit_size == 0) return NULL;

    if (commit_size > reserve_size) {
        reserve_size = commit_size;
    }
    
    void* reserved = orbit_virtual_reserve(reserve_size);
    if (!reserved) return NULL;
    
    if (!orbit_virtual_commit(reserved, commit_size)) {
        orbit_virtual_release(reserved, reserve_size);
        return NULL;
    }
    
    OrbitArena* arena = (OrbitArena*)malloc(sizeof(OrbitArena));
    if (!arena) {
        orbit_virtual_release(reserved, reserve_size);
        return NULL;
    }
    
    arena->base = (unsigned char*)reserved;
    arena->cursor = (unsigned char*)reserved;
    arena->committed_end = (unsigned char*)reserved + commit_size;
    arena->reserved_end = (unsigned char*)reserved + reserve_size;
    
    arena->page_size = page_size;
    arena->requested_bytes = 0;
    arena->aligned_bytes = 0;
    arena->peak_used = 0;
    arena->committed_bytes = commit_size;
    arena->reserved_bytes = reserve_size;
    arena->max_rule = orbit_arena_max_rule_from_env();
    arena->ceiling_hit = false;
    
    arena->generation = 1;
    arena->alloc_count = 0;
    arena->parent = NULL;
    
    arena->local_string_pool = NULL;
    arena->overflow_list = NULL;
    
    /* Compatibility alias fields mirror the primary bookkeeping fields. */
    arena->buffer = (char*)arena->base;
    arena->capacity = arena->reserved_bytes;
    arena->used = 0;

    orbit_perf_record_virtual_reserved(reserve_size);
    orbit_perf_record_committed(commit_size);
    orbit_perf_record_commit_op();
    
    return arena;
}

/** @brief Release all virtual memory owned by @p arena and free the arena header itself. */
void orbit_arena_destroy(OrbitArena* arena) {
    if (!arena) return;
    
    /* Step 0: publish the interval that this arena never got to reset. Worker
     * arenas are folded at reset; the pool, a child arena, or a worker tearing
     * down has a final interval, and without this fold the allocations made
     * after the last reset would never reach the process totals. */
    orbit_perf_fold_arena(arena->alloc_count, arena->requested_bytes,
                          arena->aligned_bytes, arena->peak_used);

    /* Step 1: release all chained overflow segments. */
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        OrbitArenaOverflow* next = overflow->next;
        orbit_virtual_release(overflow->ptr, overflow->size);
        free(overflow);
        overflow = next;
    }

    /* Step 2: release the primary VA reservation. */
    orbit_virtual_release(arena->base, (size_t)(arena->reserved_end - arena->base));

    /* Step 3: tear down the interning pool if one was attached. */
    if (arena->local_string_pool) {
        orbit_string_pool_local_destroy(arena->local_string_pool);
    }
    
    free(arena);
}

#endif
