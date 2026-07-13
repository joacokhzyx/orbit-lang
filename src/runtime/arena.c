/**
 * @file  arena.c
 * @brief Epoch-based virtual-memory arena for Orbit's runtime allocator.
 *
 * Implements a region-based, deterministic memory allocator backed by OS
 * virtual memory (VirtualAlloc on Windows, mmap on POSIX).  Each arena
 * reserves a large VA range up-front and commits physical pages on demand.
 * Overflow segments are chained in a singly-linked list; a full O(1) reset
 * decommits excess pages and bumps the generation counter so stale
 * checkpoints are detected and rejected.
 */
#ifndef ORBIT_ARENA_H
#define ORBIT_ARENA_H

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <windows.h>
#else
  #include <sys/mman.h>
  #include <unistd.h>
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Arena — Region-based deterministic memory (Epochal VM Version).
 * ────────────────────────────────────────────────────────────────────── */

#ifndef ORBIT_ARENA_ALIGN
#define ORBIT_ARENA_ALIGN 16
#endif

#ifndef ORBIT_ARENA_DEFAULT_RESERVE
#define ORBIT_ARENA_DEFAULT_RESERVE (64 * 1024 * 1024) // 64 MB virtual reservation
#endif

#ifndef ORBIT_ARENA_DEFAULT_COMMIT
#define ORBIT_ARENA_DEFAULT_COMMIT (64 * 1024) // 64 KB initial physical commit
#endif

#ifndef ORBIT_ARENA_GROWTH_GRANULARITY
#define ORBIT_ARENA_GROWTH_GRANULARITY (64 * 1024) // 64 KB increments
#endif

#ifndef ORBIT_ARENA_HOT_RETENTION_LIMIT
#define ORBIT_ARENA_HOT_RETENTION_LIMIT (256 * 1024) // Retain 256 KB hot committed memory on reset
#endif

typedef struct OrbitArenaOverflow {
    struct OrbitArenaOverflow* next;
    void*                      ptr;
    size_t                     size;
} OrbitArenaOverflow;

/* Forward declaration of the per-arena string interning pool. */
struct OrbitStringPoolLocal;

typedef struct OrbitArena {
    unsigned char* base;
    unsigned char* cursor;
    unsigned char* committed_end;
    unsigned char* reserved_end;

    size_t page_size;
    size_t requested_bytes;
    size_t aligned_bytes;
    size_t peak_used;
    size_t committed_bytes;
    size_t reserved_bytes;

    uint64_t generation;
    uint64_t alloc_count;

    struct OrbitArena* parent;      /* NULL for root/global arenas */

    /* Per-arena interning table; invalidated on reset. */
    struct OrbitStringPoolLocal* local_string_pool;

    /* Singly-linked list of retired VA segments (overflow path). */
    OrbitArenaOverflow* overflow_list;

    /* compatibility fields */
    char*             buffer;       /* points to base */
    size_t            capacity;     /* total reserved capacity */
    size_t            used;         /* current used bytes */
} OrbitArena;

typedef struct {
    size_t offset;
    uint64_t generation;
} OrbitArenaCheckpoint;

/* ── Virtual Memory Abstraction ──────────────────────────────────────── */

static inline size_t orbit_get_page_size(void) {
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
#else
    long sz = sysconf(_SC_PAGESIZE);
    return sz > 0 ? (size_t)sz : 4096;
#endif
}

static inline void* orbit_virtual_reserve(size_t size) {
#ifdef _WIN32
    return VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS);
#else
    void* addr = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (addr == MAP_FAILED) ? NULL : addr;
#endif
}

static inline bool orbit_virtual_commit(void* addr, size_t size) {
    if (!addr || size == 0) return true;
#ifdef _WIN32
    return VirtualAlloc(addr, size, MEM_COMMIT, PAGE_READWRITE) != NULL;
#else
    return mprotect(addr, size, PROT_READ | PROT_WRITE) == 0;
#endif
}

static inline void orbit_virtual_decommit(void* addr, size_t size) {
    if (!addr || size == 0) return;
#ifdef _WIN32
    VirtualFree(addr, size, MEM_DECOMMIT);
#else
#ifdef MADV_DONTNEED
    madvise(addr, size, MADV_DONTNEED);
#endif
    mprotect(addr, size, PROT_NONE);
#endif
}

static inline void orbit_virtual_release(void* addr, size_t size) {
    if (!addr || size == 0) return;
#ifdef _WIN32
    VirtualFree(addr, 0, MEM_RELEASE);
#else
    munmap(addr, size);
#endif
}

/* ── Safe Overflow Checked Helpers ───────────────────────────────────── */

static inline size_t orbit_align_up(size_t size, size_t alignment) {
    if (size > SIZE_MAX - (alignment - 1)) {
        return 0; // Overflow
    }
    return (size + (alignment - 1)) & ~(alignment - 1);
}

/* Forward declarations for string pool integration */
static void orbit_string_pool_local_destroy(struct OrbitStringPoolLocal* pool);
static void orbit_string_pool_local_reset(struct OrbitStringPoolLocal* pool);

/* ── Creation & Destruction ─────────────────────────────────────────── */

/** @brief Create a new root arena, reserving at least @p initial_capacity bytes of virtual address space. */
OrbitArena* orbit_arena_create(size_t initial_capacity) {
    size_t page_size = orbit_get_page_size();
    
    size_t reserve_size = ORBIT_ARENA_DEFAULT_RESERVE;
    if (initial_capacity > reserve_size) {
        reserve_size = initial_capacity;
    }
    reserve_size = orbit_align_up(reserve_size, page_size);
    if (reserve_size == 0) return NULL;
    
    size_t commit_size = initial_capacity > 0 ? initial_capacity : ORBIT_ARENA_DEFAULT_COMMIT;
    commit_size = orbit_align_up(commit_size, page_size);
    if (commit_size == 0) return NULL;

    if (commit_size > reserve_size) {
        reserve_size = commit_size;
    }
    
    void* reserved = orbit_virtual_reserve(reserve_size);
    if (!reserved) return NULL;
    
    if (!orbit_virtual_commit(reserved, commit_size)) {
        orbit_virtual_release(reserved, reserve_size);
        return NULL;
    }
    
    OrbitArena* arena = (OrbitArena*)malloc(sizeof(OrbitArena));
    if (!arena) {
        orbit_virtual_release(reserved, reserve_size);
        return NULL;
    }
    
    arena->base = (unsigned char*)reserved;
    arena->cursor = (unsigned char*)reserved;
    arena->committed_end = (unsigned char*)reserved + commit_size;
    arena->reserved_end = (unsigned char*)reserved + reserve_size;
    
    arena->page_size = page_size;
    arena->requested_bytes = 0;
    arena->aligned_bytes = 0;
    arena->peak_used = 0;
    arena->committed_bytes = commit_size;
    arena->reserved_bytes = reserve_size;
    
    arena->generation = 1;
    arena->alloc_count = 0;
    arena->parent = NULL;
    
    arena->local_string_pool = NULL;
    arena->overflow_list = NULL;
    
    /* Compatibility alias fields mirror the primary bookkeeping fields. */
    arena->buffer = (char*)arena->base;
    arena->capacity = arena->reserved_bytes;
    arena->used = 0;

    orbit_perf_record_virtual_reserved(reserve_size);
    orbit_perf_record_committed(commit_size);
    orbit_perf_record_commit_op();
    
    return arena;
}

/** @brief Create a child arena whose parent pointer links it to @p parent for promotion operations. */
OrbitArena* orbit_arena_create_child(OrbitArena* parent, size_t initial_capacity) {
    if (!parent) return NULL;
    OrbitArena* child = orbit_arena_create(initial_capacity);
    if (child) {
        child->parent = parent;
    }
    return child;
}

/** @brief Release all virtual memory owned by @p arena and free the arena header itself. */
void orbit_arena_destroy(OrbitArena* arena) {
    if (!arena) return;
    
    /* Step 1: release all chained overflow segments. */
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        OrbitArenaOverflow* next = overflow->next;
        orbit_virtual_release(overflow->ptr, overflow->size);
        free(overflow);
        overflow = next;
    }

    /* Step 2: release the primary VA reservation. */
    orbit_virtual_release(arena->base, (size_t)(arena->reserved_end - arena->base));

    /* Step 3: tear down the interning pool if one was attached. */
    if (arena->local_string_pool) {
        orbit_string_pool_local_destroy(arena->local_string_pool);
    }
    
    free(arena);
}

/* ── Allocation ─────────────────────────────────────────────────────── */

/** @brief Allocate @p bytes from @p arena with alignment guaranteed to ORBIT_ARENA_ALIGN. Returns NULL on OOM. */
void* orbit_alloc(OrbitArena* arena, size_t bytes) {
    if (!arena || bytes == 0) return NULL;

    /* Align to ORBIT_ARENA_ALIGN boundary safely */
    size_t aligned = orbit_align_up(bytes, ORBIT_ARENA_ALIGN);
    if (aligned == 0) {
        orbit_perf_record_oom();
        return NULL; /* Overflow protection */
    }

    #ifdef ORBIT_WITH_NET
    if (current_lease) {
        if (current_lease->arena_bytes + aligned > current_lease->arena_limit) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_arena_budget_exhausted);
            orbit_perf_record_oom();
            return NULL;
        }
        current_lease->arena_bytes += aligned;
    }
    #endif

    orbit_perf_record_requested_bytes(bytes);
    unsigned char* new_cursor = arena->cursor + aligned;

    /* Fast path: fits inside currently committed space */
    if (new_cursor <= arena->committed_end) {
        void* ptr = arena->cursor;
        arena->cursor = new_cursor;
        arena->alloc_count++;
        arena->requested_bytes += bytes;
        arena->aligned_bytes += aligned;
        
        size_t current_used = (size_t)(arena->cursor - arena->base);
        if (current_used > arena->peak_used) {
            arena->peak_used = current_used;
            if (current_used > orbit_perf_stats.arena_peak_used_bytes) {
                orbit_perf_stats.arena_peak_used_bytes = current_used;
            }
        }
        
        arena->used = current_used;

        orbit_perf_record_total_alloc(aligned);
        return ptr;
    }

    /* Slow path: fits inside reservation, commit more pages */
    if (new_cursor <= arena->reserved_end) {
        size_t needed = (size_t)(new_cursor - arena->committed_end);
        size_t page_aligned = orbit_align_up(needed, arena->page_size);
        if (page_aligned == 0) {
            orbit_perf_record_oom();
            return NULL;
        }

        orbit_perf_record_commit_op();
        if (!orbit_virtual_commit(arena->committed_end, page_aligned)) {
            orbit_perf_record_oom();
            return NULL; /* Out of physical memory */
        }
        
        arena->committed_end += page_aligned;
        arena->committed_bytes += page_aligned;
        orbit_perf_record_committed(page_aligned);
        
        void* ptr = arena->cursor;
        arena->cursor = new_cursor;
        arena->alloc_count++;
        arena->requested_bytes += bytes;
        arena->aligned_bytes += aligned;
        
        size_t current_used = (size_t)(arena->cursor - arena->base);
        if (current_used > arena->peak_used) {
            arena->peak_used = current_used;
            if (current_used > orbit_perf_stats.arena_peak_used_bytes) {
                orbit_perf_stats.arena_peak_used_bytes = current_used;
            }
        }
        
        arena->used = current_used;

        orbit_perf_record_total_alloc(aligned);
        return ptr;
    }

    /* Overflow path: active segment is exhausted — allocate a fresh VA segment,
     * chain the old one into overflow_list, and satisfy the request from the new segment. */
    size_t new_reserve = aligned > ORBIT_ARENA_DEFAULT_RESERVE ? aligned : ORBIT_ARENA_DEFAULT_RESERVE;
    new_reserve = orbit_align_up(new_reserve, arena->page_size);
    if (new_reserve == 0) {
        orbit_perf_record_oom();
        return NULL;
    }
    
    void* new_mem = orbit_virtual_reserve(new_reserve);
    if (!new_mem) {
        orbit_perf_record_oom();
        return NULL;
    }
    
    size_t new_commit = aligned > ORBIT_ARENA_DEFAULT_COMMIT ? aligned : ORBIT_ARENA_DEFAULT_COMMIT;
    new_commit = orbit_align_up(new_commit, arena->page_size);
    if (new_commit == 0 || !orbit_virtual_commit(new_mem, new_commit)) {
        orbit_virtual_release(new_mem, new_reserve);
        orbit_perf_record_oom();
        return NULL;
    }
    
    /* Push the current segment onto the overflow list. */
    OrbitArenaOverflow* overflow = (OrbitArenaOverflow*)malloc(sizeof(OrbitArenaOverflow));
    if (!overflow) {
        orbit_virtual_release(new_mem, new_reserve);
        orbit_perf_record_oom();
        return NULL;
    }

    overflow->ptr  = arena->base;
    overflow->size = (size_t)(arena->reserved_end - arena->base);
    overflow->next = arena->overflow_list;
    arena->overflow_list = overflow;

    /* Redirect the arena's primary pointers to the freshly reserved segment. */
    arena->base = (unsigned char*)new_mem;
    arena->cursor = (unsigned char*)new_mem + aligned;
    arena->committed_end = (unsigned char*)new_mem + new_commit;
    arena->reserved_end = (unsigned char*)new_mem + new_reserve;
    
    arena->reserved_bytes += new_reserve;
    arena->committed_bytes += new_commit;
    
    /* Synchronise compatibility alias fields with the new active segment. */
    arena->buffer = (char*)arena->base;
    arena->capacity = new_reserve;
    arena->used = aligned;
    
    orbit_perf_record_overflow_alloc();
    orbit_perf_record_virtual_reserved(new_reserve);
    orbit_perf_record_committed(new_commit);
    orbit_perf_record_commit_op();

    void* ptr = new_mem;
    arena->alloc_count++;
    arena->requested_bytes += bytes;
    arena->aligned_bytes += aligned;
    
    orbit_perf_record_total_alloc(aligned);
    return ptr;
}

/** @brief Duplicate the C string @p src into @p arena and return a pointer to the copy. */
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

/* ── Reset (O(1) logical cleanup & decommit reclamation policy) ─────── */

/** @brief Reset @p arena to its initial state in O(1): release overflow segments, decommit excess pages, and bump the generation counter. */
void orbit_arena_reset(OrbitArena* arena) {
    if (!arena) return;

    orbit_perf_record_reset();

    /* Step 1: release all chained overflow (retired) segments. */
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        OrbitArenaOverflow* next = overflow->next;
        orbit_virtual_release(overflow->ptr, overflow->size);
        free(overflow);
        overflow = next;
    }
    arena->overflow_list = NULL;

    /* Step 2: decommit pages beyond the hot-retention watermark. */
    size_t keep_size = ORBIT_ARENA_HOT_RETENTION_LIMIT;
    size_t page_size = arena->page_size;
    keep_size = orbit_align_up(keep_size, page_size);

    size_t total_reserved = (size_t)(arena->reserved_end - arena->base);
    if (keep_size > total_reserved) {
        keep_size = total_reserved;
    }

    unsigned char* keep_end = arena->base + keep_size;
    if (arena->committed_end > keep_end) {
        size_t decommit_size = (size_t)(arena->committed_end - keep_end);
        orbit_virtual_decommit(keep_end, decommit_size);
        orbit_perf_record_decommit_op();
        arena->committed_end = keep_end;
    }

    arena->committed_bytes = (size_t)(arena->committed_end - arena->base);
    arena->reserved_bytes  = total_reserved;

    /* Step 3: rewind the bump pointer and advance the epoch generation. */
    arena->cursor         = arena->base;
    arena->requested_bytes = 0;
    arena->aligned_bytes  = 0;
    arena->alloc_count    = 0;
    arena->generation++;

    /* Synchronise compatibility alias fields. */
    arena->used     = 0;
    arena->capacity = total_reserved;
    arena->buffer   = (char*)arena->base;

    /* Step 4: invalidate the per-arena interning table. */
    if (arena->local_string_pool) {
        orbit_string_pool_local_reset(arena->local_string_pool);
    }
}

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

/* ── Diagnostics ────────────────────────────────────────────────────── */

/** @brief Return the total number of bytes currently used across the active segment and all overflow segments. */
size_t orbit_arena_used(const OrbitArena* arena) {
    if (!arena) return 0;
    size_t total_used = (size_t)(arena->cursor - arena->base);
    OrbitArenaOverflow* overflow = arena->overflow_list;
    while (overflow) {
        total_used += overflow->size; /* Each retired segment is counted in full. */
        overflow = overflow->next;
    }
    return total_used;
}

/** @brief Return the total reserved virtual address space, in bytes. */
size_t orbit_arena_capacity(const OrbitArena* arena) {
    return arena ? arena->reserved_bytes : 0;
}

/** @brief Return the cumulative allocation count since the last reset. */
uint64_t orbit_arena_alloc_count(const OrbitArena* arena) {
    return arena ? arena->alloc_count : 0;
}

#endif
