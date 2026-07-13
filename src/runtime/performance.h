#ifndef ORBIT_PERFORMANCE_H
#define ORBIT_PERFORMANCE_H

#include "inline.h"
#include <stdint.h>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <windows.h>
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Performance — Lightweight profiling counters.
 * ────────────────────────────────────────────────────────────────────── */

#ifdef _WIN32
  #define orbit_perf_atomic_add64(ptr, val) InterlockedExchangeAdd64((volatile LONG64*)(ptr), (LONG64)(val))
  #define orbit_perf_atomic_inc64(ptr) InterlockedIncrement64((volatile LONG64*)(ptr))
#else
  #define orbit_perf_atomic_add64(ptr, val) __sync_fetch_and_add((volatile uint64_t*)(ptr), (uint64_t)(val))
  #define orbit_perf_atomic_inc64(ptr) __sync_fetch_and_add((volatile uint64_t*)(ptr), 1)
#endif

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
    
    // Kynx Sovereign Telemetry
    uint64_t kynx_admissions;
    uint64_t kynx_early_rejections;
    uint64_t kynx_throttled;
    uint64_t kynx_deadline_exhausted;
    uint64_t kynx_arena_budget_exhausted;
    uint64_t kynx_request_budget_exhausted;
    uint64_t kynx_response_budget_exhausted;
    uint64_t kynx_db_query_budget_exhausted;
    uint64_t kynx_db_step_budget_exhausted;
    uint64_t kynx_table_saturations;
    uint64_t kynx_state_transitions;
    
    // Database Stats
    uint64_t db_queries;
    uint64_t db_total_cycles;
    
    // App Info
    uint64_t string_intern_hits;

    // Epochal VM Arena Stats
    uint64_t arena_alloc_count;
    uint64_t arena_requested_bytes;
    uint64_t arena_aligned_bytes;
    uint64_t arena_virtual_reserved_bytes;
    uint64_t arena_committed_bytes;
    uint64_t arena_peak_used_bytes;
    uint64_t arena_commit_operations;
    uint64_t arena_decommit_operations;
    uint64_t arena_resets;
    uint64_t arena_reuses;
    uint64_t arena_overflow_allocations;
    uint64_t arena_out_of_memory_count;
    uint64_t arena_checkpoint_count;
    uint64_t arena_rewind_count;
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
    orbit_perf_atomic_inc64(&orbit_perf_stats.request_count);
}

ORBIT_INLINE void orbit_perf_end_request(uint64_t start_cycles) {
    uint64_t end = orbit_rdtsc();
    uint64_t duration = end - start_cycles;

    orbit_perf_atomic_add64(&orbit_perf_stats.total_cycles, duration);

    // Minor race on min/max is acceptable for statistics compared to full CAS overhead
    if (duration < orbit_perf_stats.min_cycles || orbit_perf_stats.min_cycles == 0) {
        orbit_perf_stats.min_cycles = duration;
    }

    if (duration > orbit_perf_stats.max_cycles) {
        orbit_perf_stats.max_cycles = duration;
    }
}

ORBIT_INLINE void orbit_perf_record_arena_reuse(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_reuse_count);
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_reuses);
}

ORBIT_INLINE void orbit_perf_record_string_hit(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.string_intern_hits);
}

ORBIT_INLINE OrbitPerfStats orbit_perf_get_stats(void) {
    return orbit_perf_stats;
}

ORBIT_INLINE void orbit_perf_reset_stats(void) {
    // Structural reset is safe
    orbit_perf_stats = (OrbitPerfStats){0};
}

/* ── Epochal VM Arena telemetry recording helpers ────────────────────── */

static inline void orbit_perf_record_total_alloc(size_t bytes) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_alloc_count);
    orbit_perf_atomic_add64(&orbit_perf_stats.total_alloc_bytes, bytes);
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_aligned_bytes, bytes);
}

static inline void orbit_perf_record_requested_bytes(size_t bytes) {
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_requested_bytes, bytes);
}

static inline void orbit_perf_record_virtual_reserved(size_t bytes) {
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_virtual_reserved_bytes, bytes);
}

static inline void orbit_perf_record_committed(size_t bytes) {
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_committed_bytes, bytes);
}

static inline void orbit_perf_record_commit_op(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_commit_operations);
}

static inline void orbit_perf_record_decommit_op(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_decommit_operations);
}

static inline void orbit_perf_record_reset(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_resets);
}

static inline void orbit_perf_record_overflow_alloc(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_overflow_allocations);
}

static inline void orbit_perf_record_checkpoint(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_checkpoint_count);
}

static inline void orbit_perf_record_rewind(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_rewind_count);
}

static inline void orbit_perf_record_oom(void) {
    orbit_perf_atomic_inc64(&orbit_perf_stats.arena_out_of_memory_count);
}

#ifdef _MSC_VER
  #define ORBIT_THREAD_LOCAL __declspec(thread)
#else
  #define ORBIT_THREAD_LOCAL __thread
#endif

typedef struct {
    uint64_t deadline_ns;
    uint64_t cpu_fuel;
    size_t arena_bytes;
    size_t arena_limit;
    size_t request_bytes;
    size_t request_limit;
    size_t response_bytes;
    size_t response_limit;
    uint32_t db_queries;
    uint32_t db_queries_limit;
    uint64_t db_steps;
    uint64_t db_steps_limit;
    uint32_t route_id;
    uint32_t principal_id;
    uint32_t flags;
} OrbitKynxLease;

extern ORBIT_THREAD_LOCAL OrbitKynxLease* current_lease;

#endif
