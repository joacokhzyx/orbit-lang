#ifndef ORBIT_ARENA_POOL_H
#define ORBIT_ARENA_POOL_H

#include "arena.c"
#include <stdbool.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Arena Pool — Reusable arena recycling for high-throughput.
 *
 * Instead of malloc/free per request, arenas are acquired from a pool,
 * used, reset (O(1)), and returned. No allocation on the hot path.
 *
 * Configuration: pool size and default arena capacity are set at init
 * time, not hardcoded.  Overflow creates a temporary arena that is
 * destroyed on release (graceful degradation).
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    OrbitArena** arenas;
    bool*        in_use;
    int          pool_size;
    size_t       arena_capacity;
    int          active_count;     /* number currently in use */
    uint64_t     total_acquires;
    uint64_t     overflow_creates; /* arenas created beyond pool */
} OrbitArenaPool;

static OrbitArenaPool orbit_global_arena_pool = {0};

void orbit_arena_pool_init(int pool_size, size_t arena_capacity) {
    orbit_global_arena_pool.pool_size      = pool_size;
    orbit_global_arena_pool.arena_capacity = arena_capacity;
    orbit_global_arena_pool.active_count   = 0;
    orbit_global_arena_pool.total_acquires = 0;
    orbit_global_arena_pool.overflow_creates = 0;

    orbit_global_arena_pool.arenas = (OrbitArena**)calloc((size_t)pool_size, sizeof(OrbitArena*));
    orbit_global_arena_pool.in_use = (bool*)calloc((size_t)pool_size, sizeof(bool));

    for (int i = 0; i < pool_size; i++) {
        orbit_global_arena_pool.arenas[i] = orbit_arena_create(arena_capacity);
        orbit_global_arena_pool.in_use[i] = false;
    }
}

OrbitArena* orbit_arena_pool_acquire(void) {
    orbit_global_arena_pool.total_acquires++;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
        if (!orbit_global_arena_pool.in_use[i]) {
            orbit_global_arena_pool.in_use[i] = true;
            orbit_global_arena_pool.active_count++;
            orbit_perf_stats.active_arenas = (uint32_t)orbit_global_arena_pool.active_count;
            orbit_arena_reset(orbit_global_arena_pool.arenas[i]);
            return orbit_global_arena_pool.arenas[i];
        }
    }

    /* Pool exhausted — create a temporary overflow arena */
    orbit_global_arena_pool.overflow_creates++;
    return orbit_arena_create(orbit_global_arena_pool.arena_capacity);
}

void orbit_arena_pool_release(OrbitArena* arena) {
    if (!arena) return;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
        if (orbit_global_arena_pool.arenas[i] == arena) {
            orbit_global_arena_pool.in_use[i] = false;
            orbit_global_arena_pool.active_count--;
            orbit_perf_stats.active_arenas = (uint32_t)orbit_global_arena_pool.active_count;
            orbit_arena_reset(arena);
            return;
        }
    }

    /* Not from pool — was overflow, destroy it */
    orbit_arena_destroy(arena);
}

void orbit_arena_pool_cleanup(void) {
    if (!orbit_global_arena_pool.arenas) return;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
        if (orbit_global_arena_pool.arenas[i]) {
            orbit_arena_destroy(orbit_global_arena_pool.arenas[i]);
        }
    }
    free(orbit_global_arena_pool.arenas);
    free(orbit_global_arena_pool.in_use);
    orbit_global_arena_pool.arenas = NULL;
    orbit_global_arena_pool.in_use = NULL;
}

#endif
