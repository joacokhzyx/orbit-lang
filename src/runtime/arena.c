#ifndef ORBIT_ARENA_H
#define ORBIT_ARENA_H

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Arena — Region-based deterministic memory.
 *
 * Design:
 *   - Chained block allocator to ensure stable pointer addresses.
 *   - Every block is contiguous. Growth allocates a new block.
 *   - No GC, no reference counting, no tracing.
 *
 * Alignment: all allocations are aligned to ORBIT_ARENA_ALIGN bytes.
 * Growth: when capacity is exceeded, a new block is allocated.
 * ────────────────────────────────────────────────────────────────────── */

#ifndef ORBIT_ARENA_ALIGN
#define ORBIT_ARENA_ALIGN 16
#endif

typedef struct OrbitArenaBlock {
    struct OrbitArenaBlock* next;
    size_t                  capacity;
    size_t                  used;
} OrbitArenaBlock;

typedef struct OrbitArena {
    OrbitArenaBlock*  first_block;
    OrbitArenaBlock*  current_block;
    struct OrbitArena* parent;      /* NULL for root/global arenas */
    uint64_t          alloc_count;  /* total allocations (profiling) */

    /* compatibility fields */
    char*             buffer;       /* points to current_block's data buffer */
    size_t            capacity;     /* current_block's capacity */
    size_t            used;         /* current_block's used bytes */
} OrbitArena;

/* ── Creation & Destruction ─────────────────────────────────────────── */

OrbitArena* orbit_arena_create(size_t initial_capacity) {
    OrbitArena* arena = (OrbitArena*)malloc(sizeof(OrbitArena));
    if (!arena) return NULL;

    OrbitArenaBlock* first_block = (OrbitArenaBlock*)malloc(sizeof(OrbitArenaBlock) + initial_capacity);
    if (!first_block) {
        free(arena);
        return NULL;
    }

    first_block->next     = NULL;
    first_block->capacity = initial_capacity;
    first_block->used     = 0;

    arena->first_block   = first_block;
    arena->current_block = first_block;
    arena->parent        = NULL;
    arena->alloc_count   = 0;

    /* Maintain compatibility fields */
    arena->buffer        = (char*)first_block + sizeof(OrbitArenaBlock);
    arena->capacity      = initial_capacity;
    arena->used          = 0;

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

    OrbitArenaBlock* block = arena->first_block;
    while (block) {
        OrbitArenaBlock* next = block->next;
        free(block);
        block = next;
    }
    free(arena);
}

/* ── Allocation ─────────────────────────────────────────────────────── */

void* orbit_alloc(OrbitArena* arena, size_t bytes) {
    if (!arena || bytes == 0) return NULL;

    /* Align to ORBIT_ARENA_ALIGN boundary */
    size_t aligned = (bytes + (ORBIT_ARENA_ALIGN - 1)) & ~(ORBIT_ARENA_ALIGN - 1);

    /* Grow if needed: check if current block has space */
    if (arena->current_block->used + aligned > arena->current_block->capacity) {
        OrbitArenaBlock* next_block = arena->current_block->next;

        if (next_block && next_block->capacity >= aligned) {
            /* Reuse existing block from a previous reset */
            next_block->used = 0;
            arena->current_block = next_block;
        } else {
            /* Allocate a new block (double capacity of current block) */
            size_t new_cap = arena->current_block->capacity * 2;
            if (new_cap < aligned) {
                new_cap = aligned;
            }

            OrbitArenaBlock* new_block = (OrbitArenaBlock*)malloc(sizeof(OrbitArenaBlock) + new_cap);
            if (!new_block) return NULL;

            new_block->next     = NULL;
            new_block->capacity = new_cap;
            new_block->used     = 0;

            /* Free any smaller/unused subsequent blocks to avoid leakage */
            if (next_block) {
                OrbitArenaBlock* curr = next_block;
                while (curr) {
                    OrbitArenaBlock* tmp = curr->next;
                    free(curr);
                    curr = tmp;
                }
            }

            arena->current_block->next = new_block;
            arena->current_block       = new_block;
        }
    }

    void* ptr = (char*)arena->current_block + sizeof(OrbitArenaBlock) + arena->current_block->used;
    arena->current_block->used += aligned;
    arena->alloc_count++;

    /* Update compatibility fields */
    arena->buffer   = (char*)arena->current_block + sizeof(OrbitArenaBlock);
    arena->capacity = arena->current_block->capacity;
    arena->used     = arena->current_block->used;

    /* Telemetry hook */
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

    /* Reset all blocks' usage counters to 0 to allow reuse */
    OrbitArenaBlock* block = arena->first_block;
    while (block) {
        block->used = 0;
        block = block->next;
    }

    arena->current_block = arena->first_block;
    arena->alloc_count   = 0;

    /* Update compatibility fields */
    arena->buffer        = (char*)arena->first_block + sizeof(OrbitArenaBlock);
    arena->capacity      = arena->first_block->capacity;
    arena->used          = 0;
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
    if (!arena) return 0;
    size_t total_used = 0;
    OrbitArenaBlock* block = arena->first_block;
    while (block) {
        total_used += block->used;
        block = block->next;
    }
    return total_used;
}

size_t orbit_arena_capacity(const OrbitArena* arena) {
    if (!arena) return 0;
    size_t total_capacity = 0;
    OrbitArenaBlock* block = arena->first_block;
    while (block) {
        total_capacity += block->capacity;
        block = block->next;
    }
    return total_capacity;
}

uint64_t orbit_arena_alloc_count(const OrbitArena* arena) {
    return arena ? arena->alloc_count : 0;
}

#endif
