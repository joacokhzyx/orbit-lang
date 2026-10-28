#ifndef ORBIT_RT_ARENA_CHECKPOINT_C
#define ORBIT_RT_ARENA_CHECKPOINT_C

/* Checkpoint and rewind. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "string_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "crt_compat.h"

/* ── Checkpoints & Rewind ───────────────────────────────────────────── */

/** @brief Capture a lightweight checkpoint (byte offset + generation) that can be passed to orbit_arena_rewind(). */
OrbitArenaCheckpoint orbit_arena_checkpoint(const OrbitArena* arena) {
    OrbitArenaCheckpoint cp = {0, 0};
    if (!arena) return cp;
    orbit_perf_record_checkpoint();
    cp.offset = (size_t)(arena->cursor - arena->base);
    cp.generation = arena->generation;
    return cp;
}

/** @brief Rewind @p arena's bump pointer back to @p checkpoint. Returns false if the checkpoint belongs to a past epoch or is ahead of the current cursor. */
bool orbit_arena_rewind(OrbitArena* arena, OrbitArenaCheckpoint checkpoint) {
    if (!arena) return false;
    
    orbit_perf_record_rewind();

    if (checkpoint.generation != arena->generation) {
        return false; /* Invalid checkpoint from past epoch */
    }
    
    size_t current_offset = (size_t)(arena->cursor - arena->base);
    if (checkpoint.offset > current_offset) {
        return false; /* Cannot rewind forward */
    }
    
    arena->cursor = arena->base + checkpoint.offset;
    arena->used = checkpoint.offset;
    return true;
}

#endif
