#ifndef ORBIT_ARENA_POOL_H
#define ORBIT_ARENA_POOL_H

#include "arena.c"
#include <stdbool.h>

#ifdef _WIN32
#include <windows.h>
#endif

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
    volatile int* in_use;
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
    orbit_global_arena_pool.in_use = (volatile int*)calloc((size_t)pool_size, sizeof(int));

    for (int i = 0; i < pool_size; i++) {
        orbit_global_arena_pool.arenas[i] = orbit_arena_create(arena_capacity);
        orbit_global_arena_pool.in_use[i] = 0;
    }
}

OrbitArena* orbit_arena_pool_acquire(void) {
    orbit_global_arena_pool.total_acquires++;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
#ifdef _WIN32
        if (InterlockedCompareExchange((volatile LONG*)&orbit_global_arena_pool.in_use[i], 1, 0) == 0) {
#else
        if (__sync_bool_compare_and_swap(&orbit_global_arena_pool.in_use[i], 0, 1)) {
#endif
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
            orbit_global_arena_pool.active_count--;
            orbit_perf_stats.active_arenas = (uint32_t)orbit_global_arena_pool.active_count;
            orbit_arena_reset(arena);
#ifdef _WIN32
            InterlockedExchange((volatile LONG*)&orbit_global_arena_pool.in_use[i], 0);
#else
            __sync_lock_release(&orbit_global_arena_pool.in_use[i]);
#endif
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
