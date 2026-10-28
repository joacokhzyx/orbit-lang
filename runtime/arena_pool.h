/* Interface of runtime/arena_pool.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_ARENA_POOL_H
#define ORBIT_RT_ARENA_POOL_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "arena.h"
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
void orbit_arena_pool_init(int pool_size, size_t arena_capacity);
OrbitArena* orbit_arena_pool_acquire(void);
void orbit_arena_pool_release(OrbitArena* arena);
void orbit_arena_pool_cleanup(void);

#endif
