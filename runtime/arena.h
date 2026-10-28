/* Interface of runtime/arena.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_ARENA_H
#define ORBIT_RT_ARENA_H

#include "module_prelude.h"

#include "performance.h"
#include "types.h"

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
OrbitArena* orbit_arena_create(size_t initial_capacity);
OrbitArena* orbit_arena_create_child(OrbitArena* parent, size_t initial_capacity);
void orbit_arena_destroy(OrbitArena* arena);

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
void orbit_set_oom_handler(OrbitOomHandler handler);
OrbitOomHandler orbit_get_oom_handler(void);
void orbit_request_oom_install(void);
void orbit_request_oom_arm(jmp_buf* target);
void orbit_request_oom_disarm(void);
const char* orbit_request_oom_message(void);
void* orbit_alloc_try(OrbitArena* arena, size_t bytes);
void* orbit_alloc(OrbitArena* arena, size_t bytes);
char* orbit_arena_strdup(OrbitArena* arena, const char* src);
void orbit_arena_reset(OrbitArena* arena);
OrbitArenaCheckpoint orbit_arena_checkpoint(const OrbitArena* arena);
bool orbit_arena_rewind(OrbitArena* arena, OrbitArenaCheckpoint checkpoint);
void* orbit_arena_promote(OrbitArena* child, const void* ptr, size_t bytes);
size_t orbit_arena_used(const OrbitArena* arena);
size_t orbit_arena_capacity(const OrbitArena* arena);
uint64_t orbit_arena_alloc_count(const OrbitArena* arena);
size_t orbit_arena_peak_used(const OrbitArena* arena);
size_t orbit_arena_active_bytes(const OrbitArena* arena);
int orbit_arena_overflowed(const OrbitArena* arena);

/* The first call is a race: several threads can read the pointer above as NULL
 * before any of them has published an arena. The shape without this lock
 * (check, create, assign) then created one arena per racing caller and leaked
 * every one but the last -- they became unreachable when the loser's pointer
 * was overwritten in the global. Only the create is guarded, so a call site
 * that finds the arena already there never takes the lock. */
#ifdef _WIN32
#else
#endif
OrbitArena* orbit_arena_get_global(void);

#endif
