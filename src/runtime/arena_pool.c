/**
 * @file  arena_pool.c
 * @brief Thread-safe arena recycling pool for Orbit's request pipeline.
 *
 * Maintains a fixed-size pool of pre-allocated arenas so that each incoming
 * request can acquire a ready-to-use, already-committed arena without paying
 * for a fresh virtual-memory reservation.  Acquisition and release use
 * lock-free compare-and-swap on a per-slot in-use flag.  When the pool is
 * exhausted an overflow (temporary) arena is created and destroyed on release.
 */
#ifndef ORBIT_ARENA_POOL_H
#define ORBIT_ARENA_POOL_H

#include "arena.c"
#include <stdbool.h>

#ifdef _WIN32
#include <windows.h>
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Arena Pool — Reusable arena recycling (Concurrency Safe).
 * ────────────────────────────────────────────────────────────────────── */

#ifdef _WIN32
  #define orbit_atomic_inc32(ptr) InterlockedIncrement((volatile LONG*)(ptr))
  #define orbit_atomic_dec32(ptr) InterlockedDecrement((volatile LONG*)(ptr))
  #define orbit_atomic_inc64(ptr) InterlockedIncrement64((volatile LONG64*)(ptr))
#else
  #define orbit_atomic_inc32(ptr) __sync_fetch_and_add((volatile int*)(ptr), 1)
  #define orbit_atomic_dec32(ptr) __sync_fetch_and_sub((volatile int*)(ptr), 1)
  #define orbit_atomic_inc64(ptr) __sync_fetch_and_add((volatile uint64_t*)(ptr), 1)
#endif

typedef struct {
    OrbitArena** arenas;
    volatile int* in_use;
    int          pool_size;
    size_t       arena_capacity;
    volatile int active_count;     /* atomic */
    uint64_t     total_acquires;   /* atomic */
    uint64_t     overflow_creates; /* atomic */
} OrbitArenaPool;

static OrbitArenaPool orbit_global_arena_pool = {0};

/** @brief Allocate and initialise @p pool_size arenas, each with @p arena_capacity bytes of initial capacity. */
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

/** @brief Acquire a free arena from the pool, resetting it before use.  Returns a temporary overflow arena if the pool is exhausted. */
OrbitArena* orbit_arena_pool_acquire(void) {
    orbit_atomic_inc64(&orbit_global_arena_pool.total_acquires);

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
#ifdef _WIN32
        if (InterlockedCompareExchange((volatile LONG*)&orbit_global_arena_pool.in_use[i], 1, 0) == 0) {
#else
        if (__sync_bool_compare_and_swap(&orbit_global_arena_pool.in_use[i], 0, 1)) {
#endif
            orbit_atomic_inc32(&orbit_global_arena_pool.active_count);
            orbit_perf_stats.active_arenas = (uint32_t)orbit_global_arena_pool.active_count;
            orbit_arena_reset(orbit_global_arena_pool.arenas[i]);
            return orbit_global_arena_pool.arenas[i];
        }
    }

    /* Pool fully in use — allocate a temporary arena that will be destroyed on release. */
    orbit_atomic_inc64(&orbit_global_arena_pool.overflow_creates);
    return orbit_arena_create(orbit_global_arena_pool.arena_capacity);
}

/** @brief Return @p arena to the pool (reset + mark free), or destroy it if it was an overflow arena. */
void orbit_arena_pool_release(OrbitArena* arena) {
    if (!arena) return;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
        if (orbit_global_arena_pool.arenas[i] == arena) {
            orbit_atomic_dec32(&orbit_global_arena_pool.active_count);
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

    /* Arena was not pooled (overflow path) — release it immediately. */
    orbit_arena_destroy(arena);
}

/** @brief Destroy all pooled arenas and free the pool's control arrays. */
void orbit_arena_pool_cleanup(void) {
    if (!orbit_global_arena_pool.arenas) return;

    for (int i = 0; i < orbit_global_arena_pool.pool_size; i++) {
        if (orbit_global_arena_pool.arenas[i]) {
            orbit_arena_destroy(orbit_global_arena_pool.arenas[i]);
        }
    }
    free(orbit_global_arena_pool.arenas);
    free((void*)orbit_global_arena_pool.in_use);
    orbit_global_arena_pool.arenas = NULL;
    orbit_global_arena_pool.in_use = NULL;
}

#endif
