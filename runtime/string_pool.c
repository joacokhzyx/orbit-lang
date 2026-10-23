/**
 * @file  string_pool.c
 * @brief Arena-backed interned string pool for Orbit's runtime.
 *
 * Deduplicates string literals and identifiers at runtime by storing
 * a single canonical copy in the epoch arena.  Lookups are O(n) over
 * the pool; suitable for the small string sets typical in web handlers.
 */
#ifndef ORBIT_STRING_POOL_H
#define ORBIT_STRING_POOL_H

#include "arena.c"
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

static inline void orbit_string_pool_local_init(OrbitArena* arena) {
    OrbitStringPoolLocal* pool = (OrbitStringPoolLocal*)malloc(sizeof(OrbitStringPoolLocal));
    if (!pool) return;
    pool->strings = (const char**)calloc(4096, sizeof(const char*));
    pool->lengths = (size_t*)calloc(4096, sizeof(size_t));
    if (!pool->strings || !pool->lengths) {
        free(pool->strings);
        free(pool->lengths);
        free(pool);
        return;
    }
    pool->capacity = 4096;
    pool->count = 0;
    arena->local_string_pool = pool;
}

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

static inline void orbit_string_pool_local_grow(OrbitStringPoolLocal* pool) {
    int new_cap = pool->capacity * 2;
    const char** new_strings = (const char**)malloc((size_t)new_cap * sizeof(const char*));
    size_t* new_lengths = (size_t*)malloc((size_t)new_cap * sizeof(size_t));
    if (!new_strings || !new_lengths) {
        free(new_strings);
        free(new_lengths);
        return;
    }
    if (pool->count > 0) {
        memcpy(new_strings, pool->strings, (size_t)pool->count * sizeof(const char*));
        memcpy(new_lengths, pool->lengths, (size_t)pool->count * sizeof(size_t));
    }
    free(pool->strings);
    free(pool->lengths);
    pool->strings = new_strings;
    pool->lengths = new_lengths;
    pool->capacity = new_cap;
}

/* Stubs for backwards compatibility in existing compiled assets */
void orbit_string_pool_init(int capacity) {
    (void)capacity;
}

void orbit_string_pool_cleanup(void) {
}

ORBIT_INLINE const char* orbit_string_intern(OrbitArena* arena, const char* str) {
    if (ORBIT_UNLIKELY(!str || !arena)) return NULL;

    size_t len = strlen(str);

    if (ORBIT_UNLIKELY(!arena->local_string_pool)) {
        orbit_string_pool_local_init(arena);
    }

    OrbitStringPoolLocal* pool = arena->local_string_pool;
    if (pool) {
        /* Search local entries */
        for (int i = 0; i < pool->count; i++) {
            if (pool->lengths[i] == len) {
                if (memcmp(pool->strings[i], str, len) == 0) {
                    orbit_perf_stats.string_intern_hits++;
                    return pool->strings[i];
                }
            }
        }
    }

    /* Allocate in arena */
    char* new_str = (char*)orbit_alloc(arena, len + 1);
    if (!new_str) return str;
    memcpy(new_str, str, len);
    new_str[len] = '\0';

    if (pool) {
        if (pool->count >= pool->capacity) {
            orbit_string_pool_local_grow(pool);
            /* The cache is optional: when growth fails, return the interned
             * copy without recording it rather than writing past the arrays. */
            if (pool->count >= pool->capacity) return new_str;
        }
        pool->strings[pool->count] = new_str;
        pool->lengths[pool->count] = len;
        pool->count++;
    }

    return new_str;
}


#endif
