#ifndef ORBIT_RT_STRING_POOL_C
#define ORBIT_RT_STRING_POOL_C

#include "module_prelude.h"
#include "string_pool.h"
#include "types.h"
#include "arena.h"
#include "arena.h"
#include "inline.h"
#include <string.h>
#include <stdlib.h>

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
