#ifndef ORBIT_RT_ARENA_CHILD_C
#define ORBIT_RT_ARENA_CHILD_C

/* Child arenas and promotion into the parent. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

/** @brief Create a child arena whose parent pointer links it to @p parent for promotion operations. */
OrbitArena* orbit_arena_create_child(OrbitArena* parent, size_t initial_capacity) {
    if (!parent) return NULL;
    OrbitArena* child = orbit_arena_create(initial_capacity);
    if (child) {
        child->parent = parent;
        child->max_rule = parent->max_rule;
    }
    return child;
}

/* ── Promote: copy values (trivially copyable block promotion) ──────── */

/** @brief Copy @p bytes from @p ptr into the parent of @p child, effectively promoting short-lived data to a longer-lived arena. */
void* orbit_arena_promote(OrbitArena* child, const void* ptr, size_t bytes) {
    if (!child || !child->parent || !ptr || bytes == 0) return NULL;
    
    /* Checked addition/overflow validation for copying */
    void* promoted = orbit_alloc(child->parent, bytes);
    if (promoted) {
        memcpy(promoted, ptr, bytes);
    }
    return promoted;
}

#endif
