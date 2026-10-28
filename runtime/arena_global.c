#ifndef ORBIT_RT_ARENA_GLOBAL_C
#define ORBIT_RT_ARENA_GLOBAL_C

/* The process-wide fallback arena. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

static OrbitArena* volatile g_orbit_global_fallback_arena = NULL;
#ifdef _WIN32
static volatile LONG g_orbit_global_fallback_lock = 0;

static void orbit_global_fallback_lock_acquire(void) {
    while (InterlockedCompareExchange(&g_orbit_global_fallback_lock, 1, 0) != 0) {
        YieldProcessor();
    }
}

static void orbit_global_fallback_lock_release(void) {
    InterlockedExchange(&g_orbit_global_fallback_lock, 0);
}
#else
static volatile int g_orbit_global_fallback_lock = 0;

static void orbit_global_fallback_lock_acquire(void) {
    while (!__sync_bool_compare_and_swap(&g_orbit_global_fallback_lock, 0, 1)) {
    }
}

static void orbit_global_fallback_lock_release(void) {
    __sync_lock_release(&g_orbit_global_fallback_lock);
}
#endif

OrbitArena* orbit_arena_get_global(void) {
    OrbitArena* arena = g_orbit_global_fallback_arena;
    if (arena) return arena;

    orbit_global_fallback_lock_acquire();
    if (!g_orbit_global_fallback_arena) {
        /* A worker commits this much and grows on demand; the 64 MB default
         * belongs in the reservation, not in the first call's commit charge. */
        g_orbit_global_fallback_arena = orbit_arena_create(131072);
    }
    arena = g_orbit_global_fallback_arena;
    orbit_global_fallback_lock_release();
    return arena;
}

#endif
