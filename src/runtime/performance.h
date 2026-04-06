#ifndef ORBIT_PERFORMANCE_H
#define ORBIT_PERFORMANCE_H

#include "inline.h"
#include <stdint.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Performance — Lightweight profiling counters.
 *
 * Uses RDTSC for sub-microsecond cycle counting on x86/x64.
 * Falls back to zero on other architectures (safe degradation).
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    // Request Stats
    uint64_t request_count;
    uint64_t total_cycles;
    uint64_t min_cycles;
    uint64_t max_cycles;
    
    // Memory Stats
    uint64_t arena_reuse_count;
    uint64_t total_alloc_bytes;
    uint32_t active_arenas;
    
    // Security Stats
    uint64_t kynx_blocks;
    uint32_t kynx_tracked_ips;
    
    // Database Stats
    uint64_t db_queries;
    uint64_t db_total_cycles;
    
    // App Info
    uint64_t string_intern_hits;
} OrbitPerfStats;

static OrbitPerfStats orbit_perf_stats = {0};

ORBIT_INLINE uint64_t orbit_rdtsc(void) {
#if defined(__x86_64__) || defined(_M_X64)
    uint32_t lo, hi;
    __asm__ __volatile__ ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#elif defined(_M_IX86)
    __asm { rdtsc }
#else
    return 0;
#endif
}

ORBIT_INLINE void orbit_perf_start_request(void) {
    orbit_perf_stats.request_count++;
}

ORBIT_INLINE void orbit_perf_end_request(uint64_t start_cycles) {
    uint64_t end = orbit_rdtsc();
    uint64_t duration = end - start_cycles;

    orbit_perf_stats.total_cycles += duration;

    if (ORBIT_UNLIKELY(duration < orbit_perf_stats.min_cycles || orbit_perf_stats.min_cycles == 0)) {
        orbit_perf_stats.min_cycles = duration;
    }

    if (ORBIT_UNLIKELY(duration > orbit_perf_stats.max_cycles)) {
        orbit_perf_stats.max_cycles = duration;
    }
}

ORBIT_INLINE void orbit_perf_record_arena_reuse(void) {
    orbit_perf_stats.arena_reuse_count++;
}

ORBIT_INLINE void orbit_perf_record_string_hit(void) {
    orbit_perf_stats.string_intern_hits++;
}

ORBIT_INLINE OrbitPerfStats orbit_perf_get_stats(void) {
    return orbit_perf_stats;
}

ORBIT_INLINE void orbit_perf_reset_stats(void) {
    orbit_perf_stats = (OrbitPerfStats){0};
}

#endif
