#ifndef ORBIT_ARENA_H
#define ORBIT_ARENA_H

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Arena — Region-based deterministic memory.
 *
 * Design:
 *   - Every Arena is a contiguous bump allocator.
 *   - Arenas form a hierarchy: Global → Request → Computation.
 *   - A child Arena can read from its parent (parent outlives child).
 *   - Cleanup is O(1): reset the bump pointer.
 *   - No GC, no reference counting, no tracing.
 *
 * Alignment: all allocations are aligned to ORBIT_ARENA_ALIGN bytes.
 * Growth: when capacity is exceeded, the buffer doubles (realloc).
 * ────────────────────────────────────────────────────────────────────── */

#ifndef ORBIT_ARENA_ALIGN
#define ORBIT_ARENA_ALIGN 16
#endif

typedef struct OrbitArena {
    char*            buffer;
    size_t           capacity;
    size_t           used;
    struct OrbitArena* parent;      /* NULL for root/global arenas */
    uint64_t         alloc_count;   /* total allocations (profiling) */
} OrbitArena;

/* ── Creation & Destruction ─────────────────────────────────────────── */

OrbitArena* orbit_arena_create(size_t initial_capacity) {
    OrbitArena* arena = (OrbitArena*)malloc(sizeof(OrbitArena));
    if (!arena) return NULL;

    arena->buffer = (char*)malloc(initial_capacity);
    if (!arena->buffer) {
        free(arena);
        return NULL;
    }

    arena->capacity    = initial_capacity;
    arena->used        = 0;
    arena->parent      = NULL;
    arena->alloc_count = 0;
    return arena;
}

OrbitArena* orbit_arena_create_child(OrbitArena* parent, size_t initial_capacity) {
    OrbitArena* child = orbit_arena_create(initial_capacity);
    if (child) {
        child->parent = parent;
    }
    return child;
}

void orbit_arena_destroy(OrbitArena* arena) {
    if (!arena) return;
    free(arena->buffer);
    free(arena);
}

/* ── Allocation ─────────────────────────────────────────────────────── */

void* orbit_alloc(OrbitArena* arena, size_t bytes) {
    if (!arena || bytes == 0) return NULL;

    /* Align to ORBIT_ARENA_ALIGN boundary */
    size_t aligned = (bytes + (ORBIT_ARENA_ALIGN - 1)) & ~(ORBIT_ARENA_ALIGN - 1);

    /* Grow if needed (double until it fits) */
    if (arena->used + aligned > arena->capacity) {
        size_t new_cap = arena->capacity * 2;
        while (new_cap < arena->used + aligned) {
            new_cap *= 2;
        }

        char* new_buf = (char*)realloc(arena->buffer, new_cap);
        if (!new_buf) return NULL;

        arena->buffer   = new_buf;
        arena->capacity = new_cap;
    }

    void* ptr = arena->buffer + arena->used;
    arena->used += aligned;
    arena->alloc_count++;

    // Telemetry hook
    orbit_perf_stats.total_alloc_bytes += aligned;
    
    return ptr;
}

/* Arena-allocated strdup */
char* orbit_arena_strdup(OrbitArena* arena, const char* src) {
    if (!src) return NULL;
    size_t len = strlen(src);
    char* dst = (char*)orbit_alloc(arena, len + 1);
    if (dst) {
        memcpy(dst, src, len);
        dst[len] = '\0';
    }
    return dst;
}

/* ── Reset (O(1) cleanup) ──────────────────────────────────────────── */

void orbit_arena_reset(OrbitArena* arena) {
    if (!arena) return;
    arena->used        = 0;
    arena->alloc_count = 0;
    /* buffer is NOT freed — reused for next lifecycle */
}

/* ── Promote: copy a value from child arena to parent arena ─────── */

void* orbit_arena_promote(OrbitArena* child, const void* ptr, size_t bytes) {
    if (!child || !child->parent || !ptr) return NULL;
    void* promoted = orbit_alloc(child->parent, bytes);
    if (promoted) {
        memcpy(promoted, ptr, bytes);
    }
    return promoted;
}

/* ── Diagnostics ────────────────────────────────────────────────────── */

size_t orbit_arena_used(const OrbitArena* arena) {
    return arena ? arena->used : 0;
}

size_t orbit_arena_capacity(const OrbitArena* arena) {
    return arena ? arena->capacity : 0;
}

uint64_t orbit_arena_alloc_count(const OrbitArena* arena) {
    return arena ? arena->alloc_count : 0;
}

#endif
