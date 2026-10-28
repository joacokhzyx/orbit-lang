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
ORBIT_XLINK void orbit_string_pool_local_destroy(OrbitStringPoolLocal* pool);
ORBIT_XLINK void orbit_string_pool_local_reset(OrbitStringPoolLocal* pool);
void orbit_string_pool_init(int capacity);
void orbit_string_pool_cleanup(void);

#endif
