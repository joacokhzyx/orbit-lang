#ifndef ORBIT_STRING_POOL_H
#define ORBIT_STRING_POOL_H

#include "arena.c"
#include "inline.h"
#include <string.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit String Pool — Arena-backed string interning.
 *
 * Deduplicates string allocations within an Arena's lifecycle.
 * When the Arena resets, interned strings are naturally invalidated.
 *
 * The pool is currently global and fixed-capacity. Phase 2 will make
 * it per-Arena with dynamic growth.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    const char** strings;
    size_t*      lengths;
    int          count;
    int          capacity;
    uint64_t     hit_count;
    uint64_t     miss_count;
} OrbitStringPool;

static OrbitStringPool orbit_string_pool = {0};

void orbit_string_pool_init(int capacity) {
    orbit_string_pool.capacity   = capacity;
    orbit_string_pool.count      = 0;
    orbit_string_pool.hit_count  = 0;
    orbit_string_pool.miss_count = 0;
    orbit_string_pool.strings    = (const char**)calloc((size_t)capacity, sizeof(const char*));
    orbit_string_pool.lengths    = (size_t*)calloc((size_t)capacity, sizeof(size_t));
}

void orbit_string_pool_cleanup(void) {
    free(orbit_string_pool.strings);
    free(orbit_string_pool.lengths);
    orbit_string_pool.strings  = NULL;
    orbit_string_pool.lengths  = NULL;
    orbit_string_pool.count    = 0;
    orbit_string_pool.capacity = 0;
}

ORBIT_INLINE const char* orbit_string_intern(OrbitArena* arena, const char* str) {
    if (ORBIT_UNLIKELY(!str)) return NULL;

    size_t len = strlen(str);

    /* Search existing entries */
    for (int i = 0; i < orbit_string_pool.count; i++) {
        if (ORBIT_LIKELY(orbit_string_pool.lengths[i] == len)) {
            if (memcmp(orbit_string_pool.strings[i], str, len) == 0) {
                orbit_string_pool.hit_count++;
                return orbit_string_pool.strings[i];
            }
        }
    }

    orbit_string_pool.miss_count++;

    /* Allocate in arena */
    char* new_str = (char*)orbit_alloc(arena, len + 1);
    if (!new_str) return str;
    memcpy(new_str, str, len);
    new_str[len] = '\0';

    /* Store if capacity allows */
    if (orbit_string_pool.count < orbit_string_pool.capacity) {
        orbit_string_pool.strings[orbit_string_pool.count] = new_str;
        orbit_string_pool.lengths[orbit_string_pool.count] = len;
        orbit_string_pool.count++;
    }

    return new_str;
}

ORBIT_INLINE bool orbit_string_equals_fast(const char* a, const char* b) {
    if (ORBIT_LIKELY(a == b)) return true;     /* pointer equality from interning */
    if (ORBIT_UNLIKELY(!a || !b)) return false;
    return strcmp(a, b) == 0;
}

#endif
