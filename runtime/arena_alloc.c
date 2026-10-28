#ifndef ORBIT_RT_ARENA_ALLOC_C
#define ORBIT_RT_ARENA_ALLOC_C

/* Allocation: orbit_alloc, orbit_alloc_try, orbit_arena_strdup, the ceiling
 * check, growth and overflow segments, and the aborting out-of-memory default.
 * Everything else that touches the OOM handler lives in arena_oom. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "arena_internal.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include "crt_compat.h"

/* Message building without printf: the OOM texts need only strings, unsigned
 * decimals and one pointer, and the format engine they would pull in costs
 * more .text than the rest of the allocator. Output is cut at cap. */
ORBIT_XLINK ORBIT_NOINLINE size_t orbit_oom_put(char* buf, size_t cap, size_t n, const char* s) {
    while (*s && n + 1 < cap) buf[n++] = *s++;
    buf[n] = '\0';
    return n;
}

ORBIT_XLINK ORBIT_NOINLINE size_t orbit_oom_put_u(char* buf, size_t cap, size_t n, unsigned long long v) {
    char digits[24];
    int d = 0;
    do { digits[d++] = (char)('0' + (int)(v % 10)); v /= 10; } while (v);
    while (d && n + 1 < cap) buf[n++] = digits[--d];
    buf[n] = '\0';
    return n;
}

static size_t orbit_oom_put_p(char* buf, size_t cap, size_t n, const void* p) {
    char digits[24];
    int d = 0;
    uintptr_t v = (uintptr_t)p;
    do { digits[d++] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
    n = orbit_oom_put(buf, cap, n, "0x");
    while (d && n + 1 < cap) buf[n++] = digits[--d];
    buf[n] = '\0';
    return n;
}

/* "arena <p> holds <used> of <cap> bytes in <count> allocations" */
ORBIT_XLINK size_t orbit_oom_put_holds(char* buf, size_t cap, size_t n, OrbitArena* arena) {
    n = orbit_oom_put(buf, cap, n, "arena ");
    n = orbit_oom_put_p(buf, cap, n, arena);
    n = orbit_oom_put(buf, cap, n, " holds ");
    n = orbit_oom_put_u(buf, cap, n, arena ? arena->used : 0);
    n = orbit_oom_put(buf, cap, n, " of ");
    n = orbit_oom_put_u(buf, cap, n, arena ? arena->capacity : 0);
    n = orbit_oom_put(buf, cap, n, " bytes in ");
    n = orbit_oom_put_u(buf, cap, n, arena ? arena->alloc_count : 0);
    return orbit_oom_put(buf, cap, n, " allocations");
}

/* The report goes out through one write on the stderr handle: the format and
 * stream machinery fputs/fflush(stderr) pulled in cost more .text than the
 * rest of the allocator. The Windows C runtime opens stderr in text mode, so
 * the line ends in CR LF as it did through fputs. */
ORBIT_XLINK void orbit_oom_abort_default(OrbitArena* arena, size_t bytes) {
    char line[512];
    size_t n = 0;
    fflush(stdout);
    n = orbit_oom_put(line, sizeof line - 1, n, "orbit: ");
    if (arena && arena->ceiling_hit) {
        n = orbit_oom_put(line, sizeof line - 1, n, "arena ceiling reached allocating ");
        n = orbit_oom_put_u(line, sizeof line - 1, n, bytes);
        n = orbit_oom_put(line, sizeof line - 1, n, " bytes; ");
        n = orbit_oom_put_u(line, sizeof line - 1, n, arena->committed_bytes);
        n = orbit_oom_put(line, sizeof line - 1, n, " of ");
        n = orbit_oom_put_u(line, sizeof line - 1, n, arena->max_rule);
        n = orbit_oom_put(line, sizeof line - 1, n, " bytes committed, the limit is ");
        n = orbit_oom_put_u(line, sizeof line - 1, n, arena->max_rule / (1024 * 1024));
        n = orbit_oom_put(line, sizeof line - 1, n, " MB from ORBIT_ARENA_MAX_MB");
    } else {
        n = orbit_oom_put(line, sizeof line - 1, n, "out of memory allocating ");
        n = orbit_oom_put_u(line, sizeof line - 1, n, bytes);
        n = orbit_oom_put(line, sizeof line - 1, n, " bytes");
        if (arena) {
            n = orbit_oom_put(line, sizeof line - 1, n, "; ");
            n = orbit_oom_put_holds(line, sizeof line - 1, n, arena);
        }
    }
#ifdef _WIN32
    n = orbit_oom_put(line, sizeof line, n, "\r\n");
    {
        DWORD written = 0;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), line, (DWORD)n, &written, NULL);
    }
#else
    n = orbit_oom_put(line, sizeof line, n, "\n");
    {
        ssize_t w = write(2, line, n);
        (void)w;
    }
#endif
    abort();
}

ORBIT_XLINK OrbitOomHandler orbit_oom_handler = orbit_oom_abort_default;

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

    if (current_lease) {
        /* Compare against the room left, not the sum: aligned can be near
         * SIZE_MAX, and arena_bytes + aligned would wrap below the limit. */
        if (current_lease->arena_bytes > current_lease->arena_limit ||
            aligned > current_lease->arena_limit - current_lease->arena_bytes) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_arena_budget_exhausted);
            orbit_perf_record_oom();
            return NULL;
        }
        current_lease->arena_bytes += aligned;
    }

    /* Compare sizes, never the advanced pointer: cursor + aligned wraps when
     * aligned is huge (a length computed from an unchecked n + 1 or
     * elem_size * cap), and a wrapped pointer compares below committed_end,
     * which would hand back a block far larger than the reservation. */
    bool fits_reserved = aligned <= (size_t)(arena->reserved_end - arena->cursor);
    unsigned char* new_cursor = fits_reserved ? arena->cursor + aligned : arena->cursor;

    /* Fast path: fits inside currently committed space.
     * Telemetry is private to this arena and is joined into the process
     * totals once per request by orbit_arena_reset. Writing the four globals
     * here put a store per allocation on a line every worker shares; the join
     * is four RMWs per request instead, and it is exact, where the plain
     * stores here were approximate by design. */
    if (fits_reserved && new_cursor <= arena->committed_end) {
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
    if (fits_reserved) {
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

#endif
