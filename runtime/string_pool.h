/* Interface of runtime/string_pool.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_STRING_POOL_H
#define ORBIT_RT_STRING_POOL_H

#include "module_prelude.h"


#include "arena.h"
#include "inline.h"
#include <string.h>
#include <stdlib.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit String Pool — Localized generation-aware interning.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct OrbitStringPoolLocal {
    const char** strings;
    size_t*      lengths;
    int          count;
    int          capacity;
} OrbitStringPoolLocal;

/* Inline so that arena_destroy and arena_reset do not pull a string_pool
 * member into every program: the pool is only created by orbit_string_intern,
 * which no generated program calls. */
static inline void orbit_string_pool_local_destroy(OrbitStringPoolLocal* pool) {
    if (!pool) return;
    free(pool->strings);
    free(pool->lengths);
    free(pool);
}

static inline void orbit_string_pool_local_reset(OrbitStringPoolLocal* pool) {
    if (!pool) return;
    pool->count = 0;
}

#endif
