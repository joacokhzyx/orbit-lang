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
#include <stdio.h>
#include <setjmp.h>
#include "crt_compat.h"

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

/* Fallback ceiling on committed bytes when the platform will not report its
 * physical memory. Normally ORBIT_ARENA_MAX_MB names the ceiling, and when it
 * does not the default is three quarters of physical memory. */
#ifndef ORBIT_ARENA_DEFAULT_MAX
#define ORBIT_ARENA_DEFAULT_MAX ((size_t)2048 * 1024 * 1024)
#endif

#ifndef ORBIT_ARENA_GROWTH_GRANULARITY
#define ORBIT_ARENA_GROWTH_GRANULARITY (64 * 1024) // 64 KB increments
#endif

#ifndef ORBIT_ARENA_HOT_RETENTION_LIMIT
#define ORBIT_ARENA_HOT_RETENTION_LIMIT (256 * 1024) // Retain at least 256 KB hot committed memory on reset
#endif

#ifndef ORBIT_ARENA_HOT_RETENTION_CEILING
#define ORBIT_ARENA_HOT_RETENTION_CEILING (4 * 1024 * 1024) // Bound one arena's reset retention: worst case workers * ceiling stays resident
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
    /* The ceiling on committed bytes for this arena, from ORBIT_ARENA_MAX_MB,
     * and whether the last refusal was that ceiling rather than the OS. A
     * process that would keep growing until the machine swaps stops here with
     * one line that names the limit. */
    size_t max_rule;
    bool ceiling_hit;

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

/* A decimal megabyte count from `name`, or `fallback` when the variable is
 * unset, empty, zero, negative, non-numeric or overflows. A malformed value is
 * not a new way for a process to fail to start. */
static size_t orbit_arena_megabytes_from_env(const char* name, size_t fallback) {
    const char* raw = orbit_env_get(name);
    if (!raw || raw[0] == '\0') return fallback;

    size_t mb = 0;
    for (const char* p = raw; *p; p++) {
        if (*p < '0' || *p > '9') return fallback;
        size_t digit = (size_t)(*p - '0');
        if (mb > ((size_t)-1 - digit) / 10) return fallback;
        mb = mb * 10 + digit;
    }
    if (mb == 0) return fallback;
    if (mb > ((size_t)-1) / (1024 * 1024)) return fallback;
    return mb * 1024 * 1024;
}

/* Total physical memory, or 0 when the platform will not say. The ceiling is
 * a fraction of it, so the number does not have to be guessed per machine. */
static size_t orbit_physical_memory_bytes(void) {
#ifdef _WIN32
    MEMORYSTATUSEX status;
    status.dwLength = sizeof(status);
    if (GlobalMemoryStatusEx(&status)) return (size_t)status.ullTotalPhys;
    return 0;
#else
    long pages = sysconf(_SC_PHYS_PAGES);
    long page = sysconf(_SC_PAGE_SIZE);
    if (pages <= 0 || page <= 0) return 0;
    return (size_t)pages * (size_t)page;
#endif
}

/* The default ceiling: three quarters of physical memory, which is the point
 * past which a process that keeps committing makes the machine swap. The
 * compiled value answers only when the platform will not report the total. */
static size_t orbit_arena_default_max(void) {
    size_t physical = orbit_physical_memory_bytes();
    if (physical == 0) return ORBIT_ARENA_DEFAULT_MAX;
    return physical - physical / 4;
}

/* The committed-bytes ceiling: ORBIT_ARENA_MAX_MB, or the default above. It
 * stops a runaway allocation before the machine swaps, which is how an
 * emitter that kept growing presented as a freeze rather than as an error. */
static size_t orbit_arena_max_rule_from_env(void) {
    size_t from_env = orbit_arena_megabytes_from_env("ORBIT_ARENA_MAX_MB", 0);
    return from_env != 0 ? from_env : orbit_arena_default_max();
}

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
    arena->max_rule = orbit_arena_max_rule_from_env();
    arena->ceiling_hit = false;
    
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
        child->max_rule = parent->max_rule;
    }
    return child;
}

/** @brief Release all virtual memory owned by @p arena and free the arena header itself. */
void orbit_arena_destroy(OrbitArena* arena) {
    if (!arena) return;
    
    /* Step 0: publish the interval that this arena never got to reset. Worker
     * arenas are folded at reset; the pool, a child arena, or a worker tearing
     * down has a final interval, and without this fold the allocations made
     * after the last reset would never reach the process totals. */
    orbit_perf_fold_arena(arena->alloc_count, arena->requested_bytes,
                          arena->aligned_bytes, arena->peak_used);

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

/*
 * Allocation failure policy (oom-policy).
 *
 * orbit_alloc historically returned NULL when the arena was exhausted, and
 * almost nothing looked: of 107 orbit_alloc call sites in the runtime, 5
 * checked the result. The other 102 turned an allocation failure into a write
 * through a null pointer -- undefined behaviour that usually faults far from
 * the cause and can silently corrupt memory when it does not. orbit_string is
 * a NUL-terminated const char*, so a NULL result is also indistinguishable
 * from a legitimately empty string at most boundaries; that conflation is
 * what let `orbit fmt` report success after reducing a source file to zero
 * bytes (fmt-no-clobber).
 *
 * Failure is therefore loud by default. The default handler reports what was
 * requested and what the arena held, then aborts, so the 102 unchecked sites
 * become correct without being rewritten and the diagnostic names the arena
 * instead of a fault address.
 *
 * A program that genuinely wants to recover installs its own handler with
 * orbit_set_oom_handler, after which orbit_alloc returns NULL again and the
 * caller is responsible. orbit_alloc_try is the per-call opt-out for code that
 * must never abort, and is also what the handler-facing internals use.
 *
 * Only exhaustion reaches the handler. A NULL arena or a zero-byte request is
 * an argument error, not an out-of-memory condition, and stays a quiet NULL so
 * that argument validation (including orbit_file_write's, which fmt-no-clobber pinned)
 * keeps reporting false rather than aborting the process.
 */
typedef void (*OrbitOomHandler)(OrbitArena* arena, size_t bytes);

static void orbit_oom_abort_default(OrbitArena* arena, size_t bytes) {
    fflush(stdout);
    if (arena) {
        if (arena->ceiling_hit) {
            fprintf(stderr,
                    "orbit: arena ceiling reached allocating %zu bytes; %zu of %zu bytes committed, the limit is %zu MB from ORBIT_ARENA_MAX_MB\n",
                    bytes, arena->committed_bytes, arena->max_rule, arena->max_rule / (1024 * 1024));
        } else {
            fprintf(stderr,
                    "orbit: out of memory allocating %zu bytes; arena %p holds %zu of %zu bytes in %zu allocations\n",
                    bytes, (void*)arena, arena->used, arena->capacity, arena->alloc_count);
        }
    } else {
        fprintf(stderr, "orbit: out of memory allocating %zu bytes\n", bytes);
    }
    fflush(stderr);
    abort();
}

static OrbitOomHandler orbit_oom_handler = orbit_oom_abort_default;

/** @brief Install @p handler for allocation failure, or pass NULL to restore the aborting default. */
void orbit_set_oom_handler(OrbitOomHandler handler) {
    orbit_oom_handler = handler ? handler : orbit_oom_abort_default;
}

/** @brief The handler that orbit_alloc would call on exhaustion. NULL means the aborting default. */
OrbitOomHandler orbit_get_oom_handler(void) {
    return orbit_oom_handler;
}

/* ──────────────────────────────────────────────────────────────────────
 * Request-boundary OOM recovery.
 *
 * A Kynx lease caps one request's arena (runtime/kynx.c, 16 MB by default),
 * and a request that asked for more than the cap used to be answered by the
 * aborting default above: a refusal at the request boundary ended the
 * process. The refusal belongs to one request, so the answer does too, and
 * the generated router is the only frame that holds both the request and its
 * arena. compiler/emit/route_runtime.orb installs this handler once per
 * worker and arms it for exactly the span of one request; a refusal inside
 * that span returns to the arm point instead of exiting.
 *
 * What the longjmp skips is only the frames between the allocator and the
 * boundary, and nothing there holds a lock across an allocation: every lock
 * in the runtime is a CAS on a flag or a spinlock held around counters only
 * (runtime/arena_pool.c, runtime/kynx.c, runtime/ledger.c), and the
 * per-route ledger row is a set of atomic counters, so a skipped exit costs
 * that request its row rather than corrupting one. A refusal inside a sqlite
 * query leaks the prepared statement and no more: sqlite3 locks per call,
 * never across one.
 *
 * The handler assumes nothing about room left in the arena. The recovery
 * builds the 5xx it is about to send, and if the reservation itself is gone
 * that allocation refuses too -- with the armed flag already cleared, so the
 * aborting default runs and the process ends as it always did. An exhausted
 * arena has no room to answer with; that is the reservation's job.
 */
static ORBIT_THREAD_LOCAL jmp_buf* orbit_request_oom_target;
static ORBIT_THREAD_LOCAL int orbit_request_oom_armed;
static ORBIT_THREAD_LOCAL char orbit_request_oom_text[256];

static void orbit_request_oom_handler(OrbitArena* arena, size_t bytes) {
    if (orbit_request_oom_armed && orbit_request_oom_target) {
        orbit_request_oom_armed = 0;
        /* The facts the aborting default prints, minus the exit. The lease
         * clause is a measurement, not a claim about the cause: which arena
         * refused and what the lease held are both facts. */
        int n = snprintf(orbit_request_oom_text, sizeof(orbit_request_oom_text),
                         "503 request refused: %zu bytes refused; arena %p holds "
                         "%zu of %zu bytes in %zu allocations",
                         bytes, (void*)arena,
                         arena ? arena->used : 0, arena ? arena->capacity : 0,
                         arena ? arena->alloc_count : 0);
        #ifdef ORBIT_WITH_NET
        if (n > 0 && (size_t)n < sizeof(orbit_request_oom_text) && current_lease) {
            snprintf(orbit_request_oom_text + n,
                     sizeof(orbit_request_oom_text) - (size_t)n,
                     "; lease holds %zu of %zu bytes",
                     current_lease->arena_bytes, current_lease->arena_limit);
        }
        #else
        (void)n;
        #endif
        longjmp(*orbit_request_oom_target, 1);
    }
    orbit_oom_abort_default(arena, bytes);
}

/** @brief Install the request-boundary handler. The generated worker loop calls this once per worker. */
void orbit_request_oom_install(void) {
    orbit_set_oom_handler(orbit_request_oom_handler);
}

/** @brief Arm the boundary for one request, landing in the caller's frame.
 *
 * @p target is the caller's own jmp_buf and must outlive the request: the
 * setjmp is deliberately not taken here. longjmp can only return to a frame
 * that is still on the stack, and a helper that setjmp'd and returned would
 * hand the handler a dead frame -- measured while this was written, the
 * caller's setjmp then returned garbage instead of 1. So the frame that stays
 * alive across the request owns the buffer and calls setjmp on it; this file
 * only remembers where to land.
 */
void orbit_request_oom_arm(jmp_buf* target) {
    orbit_request_oom_target = target;
    orbit_request_oom_armed = 1;
}

/** @brief Disarm the boundary. Armed only while one request's frame is on the stack. */
void orbit_request_oom_disarm(void) {
    orbit_request_oom_armed = 0;
    orbit_request_oom_target = NULL;
}

/** @brief The refusal text the boundary answer sends, built where the facts still were. */
const char* orbit_request_oom_message(void) {
    return orbit_request_oom_text;
}

/* True when committing @p more bytes would pass the arena's ceiling. Recorded
 * on the arena so the default exhaustion report can name the limit instead of
 * blaming the operating system for a decision this process made. */
static bool orbit_arena_ceiling_reached(OrbitArena* arena, size_t more) {
    if (!arena || arena->max_rule == 0) return false;
    if (more > arena->max_rule || arena->committed_bytes > arena->max_rule - more) {
        arena->ceiling_hit = true;
        return true;
    }
    return false;
}

/** @brief Allocate @p bytes, reporting exhaustion to the handler instead of aborting. Returns NULL on OOM. */
void* orbit_alloc_try(OrbitArena* arena, size_t bytes) {
    if (!arena || bytes == 0) return NULL;
    arena->ceiling_hit = false;

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

    unsigned char* new_cursor = arena->cursor + aligned;

    /* Fast path: fits inside currently committed space.
     * Telemetry is private to this arena and is joined into the process
     * totals once per request by orbit_arena_reset. Writing the four globals
     * here put a store per allocation on a line every worker shares; the join
     * is four RMWs per request instead, and it is exact, where the plain
     * stores here were approximate by design. */
    if (new_cursor <= arena->committed_end) {
        void* ptr = arena->cursor;
        arena->cursor = new_cursor;
        arena->alloc_count++;
        arena->requested_bytes += bytes;
        arena->aligned_bytes += aligned;

        size_t current_used = (size_t)(arena->cursor - arena->base);
        if (current_used > arena->peak_used) {
            arena->peak_used = current_used;
        }

        arena->used = current_used;

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
        if (orbit_arena_ceiling_reached(arena, page_aligned)) {
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
        }
        
        arena->used = current_used;

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
    
    size_t new_commit = aligned > ORBIT_ARENA_DEFAULT_COMMIT ? aligned : ORBIT_ARENA_DEFAULT_COMMIT;
    new_commit = orbit_align_up(new_commit, arena->page_size);
    if (new_commit == 0 || orbit_arena_ceiling_reached(arena, new_commit)) {
        orbit_perf_record_oom();
        return NULL;
    }

    void* new_mem = orbit_virtual_reserve(new_reserve);
    if (!new_mem) {
        orbit_perf_record_oom();
        return NULL;
    }
    
    if (!orbit_virtual_commit(new_mem, new_commit)) {
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

    return ptr;
}

/** @brief Allocate @p bytes from @p arena with alignment guaranteed to ORBIT_ARENA_ALIGN.
 *
 *  Reports exhaustion to the current OOM handler, which aborts by default.
 *  Use orbit_alloc_try for a request that is allowed to come back NULL. */
void* orbit_alloc(OrbitArena* arena, size_t bytes) {
    void* ptr = orbit_alloc_try(arena, bytes);
    if (!ptr && arena && bytes != 0) {
        orbit_oom_handler(arena, bytes);
    }
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

    /* Step 2: decommit pages beyond the hot-retention watermark.
     *
     * The watermark is this arena's live footprint -- the pages the request just
     * touched -- clamped to [floor, ceiling] and to the active reservation,
     * rather than the fixed floor alone. A request that grew past the floor keeps
     * its pages for the next request on this worker instead of paying one
     * decommit plus a re-commit of the whole footprint every time. Below the
     * floor the policy is exactly what it was, so a service whose requests fit in
     * 256 KB sees the same reset it saw before, and the ceiling bounds the
     * resident set at workers * ORBIT_ARENA_HOT_RETENTION_CEILING. The cursor is
     * still on the previous request's end here (Step 3 rewinds it), and after an
     * overflow it points into the segment the arena last allocated from, so the
     * measurement is the live segment only. */
    size_t page_size = arena->page_size;
    size_t used_bytes = (size_t)(arena->cursor - arena->base);
    size_t keep_size = ORBIT_ARENA_HOT_RETENTION_LIMIT;
    if (used_bytes > keep_size) {
        keep_size = used_bytes;
    }
    if (keep_size > ORBIT_ARENA_HOT_RETENTION_CEILING) {
        keep_size = ORBIT_ARENA_HOT_RETENTION_CEILING;
    }
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

    /* Step 3: rewind the bump pointer and advance the epoch generation.
     *
     * The join happens here, before the interval counters are cleared: this is
     * the only place the process totals learn about arena allocations, so
     * they are exact (atomic adds, nothing lost) and cost four RMWs per
     * request rather than four stores per allocation at each bump. */
    orbit_perf_fold_arena(arena->alloc_count, arena->requested_bytes,
                          arena->aligned_bytes, arena->peak_used);

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

/** @brief Return the high-water mark of used bytes since creation/reset. */
size_t orbit_arena_peak_used(const OrbitArena* arena) {
    return arena ? arena->peak_used : 0;
}

/** @brief Bytes this arena is using in its active segment right now.
 *
 *  At the end of a request this is that request's footprint: the bump cursor
 *  only moves forward within a request (rewind is not used on the request
 *  path), so the value at exit is the request's high-water mark. After an
 *  overflow the arena has moved to a fresh segment and this counts the new
 *  segment only, which is why the per-route row reports orbit_arena_overflowed
 *  beside it. */
size_t orbit_arena_active_bytes(const OrbitArena* arena) {
    return arena ? arena->used : 0;
}

/** @brief Non-zero when this arena chained an overflow segment since its last reset. */
int orbit_arena_overflowed(const OrbitArena* arena) {
    return (arena && arena->overflow_list != NULL) ? 1 : 0;
}

static OrbitArena* volatile g_orbit_global_fallback_arena = NULL;

/* The first call is a race: several threads can read the pointer above as NULL
 * before any of them has published an arena. The shape without this lock
 * (check, create, assign) then created one arena per racing caller and leaked
 * every one but the last -- they became unreachable when the loser's pointer
 * was overwritten in the global. Only the create is guarded, so a call site
 * that finds the arena already there never takes the lock. */
#ifdef _WIN32
static volatile LONG g_orbit_global_fallback_lock = 0;

static void orbit_global_fallback_lock_acquire(void) {
    while (InterlockedCompareExchange(&g_orbit_global_fallback_lock, 1, 0) != 0) {
        YieldProcessor();
    }
}

static void orbit_global_fallback_lock_release(void) {
    InterlockedExchange(&g_orbit_global_fallback_lock, 0);
}
#else
static volatile int g_orbit_global_fallback_lock = 0;

static void orbit_global_fallback_lock_acquire(void) {
    while (!__sync_bool_compare_and_swap(&g_orbit_global_fallback_lock, 0, 1)) {
    }
}

static void orbit_global_fallback_lock_release(void) {
    __sync_lock_release(&g_orbit_global_fallback_lock);
}
#endif

OrbitArena* orbit_arena_get_global(void) {
    OrbitArena* arena = g_orbit_global_fallback_arena;
    if (arena) return arena;

    orbit_global_fallback_lock_acquire();
    if (!g_orbit_global_fallback_arena) {
        /* A worker commits this much and grows on demand; the 64 MB default
         * belongs in the reservation, not in the first call's commit charge. */
        g_orbit_global_fallback_arena = orbit_arena_create(131072);
    }
    arena = g_orbit_global_fallback_arena;
    orbit_global_fallback_lock_release();
    return arena;
}

#endif
