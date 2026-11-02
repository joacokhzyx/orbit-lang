/**
 * @file  performance.h
 * @brief RDTSC-based latency counters: request count, total, min, max, and
 *        a 100 µs-resolution histogram for percentiles.
 *
 * A percentile from a histogram is a bucket boundary, not a measurement of
 * one request, and `orbit_perf_percentile_us` returns that boundary: the
 * reported p99 is the first bucket edge holding 99% of requests. Anything
 * finer would have to invent a distribution the samples do not support.
 *
 * Exposes `orbit_rdtsc()`, `orbit_perf_start_request()`, `orbit_perf_end_request()`,
 * `orbit_perf_percentile_us()`, and `orbit_perf_report()`.  All state is kept in
 * thread-local storage so no locking is required on the hot path.
 */
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
  #define orbit_perf_atomic_inc32(ptr) (uint32_t)InterlockedIncrement((volatile LONG*)(ptr))
#else
  #define orbit_perf_atomic_add64(ptr, val) __sync_fetch_and_add((volatile uint64_t*)(ptr), (uint64_t)(val))
  #define orbit_perf_atomic_inc64(ptr) __sync_fetch_and_add((volatile uint64_t*)(ptr), 1)
  #define orbit_perf_atomic_inc32(ptr) __sync_fetch_and_add((volatile uint32_t*)(ptr), 1)
#endif

/* Monotone max under concurrency. A plain store loses an update when two
 * threads raise the same cell at once: the lower store lands last and the
 * higher value is gone. The peak this guards is a published number, so it
 * gets a CAS loop rather than the racy treatment the min/max cycle fields
 * have. Bounded retry: every failure means another thread raised the cell. */
#ifdef _WIN32
  #define orbit_perf_atomic_max64(ptr, val) do { \
      volatile LONG64* _cell = (volatile LONG64*)(ptr); \
      LONG64 _want = (LONG64)(val); \
      LONG64 _cur = InterlockedCompareExchange64(_cell, 0, 0); \
      while (_want > _cur) { \
          if (InterlockedCompareExchange64(_cell, _want, _cur) == _cur) break; \
          _cur = InterlockedCompareExchange64(_cell, 0, 0); \
      } \
  } while (0)
#else
  #define orbit_perf_atomic_max64(ptr, val) do { \
      volatile uint64_t* _cell = (volatile uint64_t*)(ptr); \
      uint64_t _want = (uint64_t)(val); \
      uint64_t _cur = *_cell; \
      while (_want > _cur) { \
          if (__sync_bool_compare_and_swap(_cell, _cur, _want)) break; \
          _cur = *_cell; \
      } \
  } while (0)
#endif

typedef struct {
    // Request Stats
    uint64_t request_count;
    uint64_t total_cycles;
    /* Responses by class, counted where one is sent: 2xx/3xx ok, else error. */
    uint64_t request_ok;
    uint64_t request_error;
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
    uint64_t kynx_route_limit_drops;
    
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

/* Ownership of the counters: the static library TU defines ORBIT_PERF_IMPL
 * and holds the single definition; a user TU built for separate compilation
 * (-DORBIT_SEPARATE_COMPILATION) binds to it through extern. Unity builds
 * define neither and keep one static copy per TU, exactly as before. The
 * inline accessors below only read whichever object is visible, so they are
 * unchanged in every mode. */
#ifdef ORBIT_PERF_IMPL
OrbitPerfStats orbit_perf_stats = {0};
#elif defined(ORBIT_SEPARATE_COMPILATION) || defined(ORBIT_RUNTIME_MODULE)
extern OrbitPerfStats orbit_perf_stats;
#else
static OrbitPerfStats orbit_perf_stats = {0};
#endif

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

/* Latency histogram: one bucket per 100 µs up to 100 ms, then 20 buckets of
 * doubling width -- 100-200 ms, 200-400, 400-800, and so on to about 105 s.
 * The linear half alone put every request slower than 100 ms into one slot, so
 * a p99 of 300 ms and a p99 of 40 s were the same number and both were answered
 * from the single longest request: not a bucket edge but a different quantity
 * altogether. Doubling keeps the reported value a bucket edge at every
 * magnitude, and the edge is still an upper boundary, never a measurement of
 * one request. Cycles convert at the same 2.5 GHz basis the average uses. */
#define ORBIT_PERF_LAT_BUCKET_US 100ULL
#define ORBIT_PERF_LAT_BUCKETS 1000
#define ORBIT_PERF_LAT_LOG_BUCKETS 20
#define ORBIT_PERF_LAT_SLOTS (ORBIT_PERF_LAT_BUCKETS + ORBIT_PERF_LAT_LOG_BUCKETS)
/* Where the linear half stops: 1000 buckets of 100 µs. */
#define ORBIT_PERF_LAT_LINEAR_US 100000ULL
/* The width a log bucket starts at: the same 100 ms, as microseconds. */
#define ORBIT_PERF_LAT_LOG_BASE_US 100000ULL
#define ORBIT_PERF_CYCLES_PER_US 2500ULL

#ifdef ORBIT_PERF_IMPL
uint64_t orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS];
uint64_t orbit_perf_lat_sum_us[ORBIT_PERF_LAT_SLOTS];
#elif defined(ORBIT_SEPARATE_COMPILATION) || defined(ORBIT_RUNTIME_MODULE)
extern uint64_t orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS];
extern uint64_t orbit_perf_lat_sum_us[ORBIT_PERF_LAT_SLOTS];
#else
static uint64_t orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS];
static uint64_t orbit_perf_lat_sum_us[ORBIT_PERF_LAT_SLOTS];
#endif

ORBIT_INLINE void orbit_perf_record_latency(uint64_t duration_cycles) {
    uint64_t us = duration_cycles / ORBIT_PERF_CYCLES_PER_US;
    uint64_t idx;
    if (us < ORBIT_PERF_LAT_LINEAR_US) {
        idx = us / ORBIT_PERF_LAT_BUCKET_US;
    } else {
        /* floor(log2(us / 100 ms)) is the doubling count above the first log
         * bucket, so slot 1000 holds 100-200 ms and each later one twice the
         * width. The loop runs at most 19 times and the last bucket absorbs
         * everything above it, which the percentile then answers from
         * max_cycles -- the one place that stays an overflow, now at 105 s
         * instead of 100 ms. */
        uint64_t q = us / ORBIT_PERF_LAT_LOG_BASE_US;
        int li = 0;
        while (q > 1 && li < ORBIT_PERF_LAT_LOG_BUCKETS - 1) {
            q >>= 1;
            li = li + 1;
        }
        idx = (uint64_t)(ORBIT_PERF_LAT_BUCKETS + li);
    }
    orbit_perf_atomic_add64(&orbit_perf_lat_hist[idx], 1);
    /* The bucket's own sum, so a percentile inside it can be anchored on what
     * was measured rather than on where the bucket ends. */
    orbit_perf_atomic_add64(&orbit_perf_lat_sum_us[idx], us);
}

/* The edges of the bucket holding the percentile: a linear bucket is 100 us
 * wide, a log bucket starts at 100 ms doubled as many times as its index past
 * the linear half and is as wide as it is tall. */
ORBIT_INLINE void orbit_perf_bucket_edges(int i, uint64_t *lo_out, uint64_t *hi_out) {
    if (i < ORBIT_PERF_LAT_BUCKETS) {
        *lo_out = (uint64_t)i * ORBIT_PERF_LAT_BUCKET_US;
        *hi_out = *lo_out + ORBIT_PERF_LAT_BUCKET_US;
        return;
    }
    uint64_t lo = ORBIT_PERF_LAT_LOG_BASE_US << (i - ORBIT_PERF_LAT_BUCKETS);
    *lo_out = lo;
    *hi_out = lo * 2;
}

/* Percentile in microseconds, estimated inside its bucket. per_mille is 500 for
 * p50, 950 for p95, 990 for p99.
 *
 * The bucket alone says only that the value lies between two edges, and the edge
 * was the answer before: a p99 of 300 ms reported 400 ms, the top of the bucket
 * that holds it. The bucket's recorded mean is a measurement of the samples
 * inside it, so the estimate is anchored there and spread by rank -- `mean +
 * width * (rank - half) / count`, clamped to the bucket. A bucket holding one
 * sample answers that sample. A bucket holding a uniform spread answers within
 * a rank step of the true value. Only the last bucket, which has no upper edge
 * of its own, is still answered from the longest request. */
ORBIT_INLINE uint64_t orbit_perf_percentile_us(uint64_t request_count, uint64_t per_mille) {
    if (request_count == 0) return 0;
    if (per_mille > 1000) per_mille = 1000;
    uint64_t target = (request_count * per_mille + 999) / 1000;
    uint64_t seen = 0;
    for (int i = 0; i < ORBIT_PERF_LAT_SLOTS; i++) {
        uint64_t in_bucket = orbit_perf_lat_hist[i];
        seen += in_bucket;
        if (seen >= target) {
            uint64_t lo = 0, hi = 0;
            orbit_perf_bucket_edges(i, &lo, &hi);
            if (i == ORBIT_PERF_LAT_SLOTS - 1) {
                return orbit_perf_stats.max_cycles / ORBIT_PERF_CYCLES_PER_US;
            }
            if (in_bucket == 0) return hi;
            uint64_t rank = target - (seen - in_bucket);
            uint64_t mean = orbit_perf_lat_sum_us[i] / in_bucket;
            /* |num| <= in_bucket, so dividing the width by the count first keeps
             * the product under the width itself: no overflow at any request
             * count, at the cost of under one microsecond per rank step. */
            int64_t num = (int64_t)(2 * rank - 1) - (int64_t)in_bucket;
            uint64_t step = (hi - lo) / in_bucket;
            int64_t est = (int64_t)mean;
            if (num >= 0) est += (int64_t)(step * (uint64_t)num);
            else est -= (int64_t)(step * (uint64_t)(-num));
            if (est < (int64_t)lo) return lo;
            if ((uint64_t)est > hi) return hi;
            return (uint64_t)est;
        }
    }
    return orbit_perf_stats.max_cycles / ORBIT_PERF_CYCLES_PER_US;
}

ORBIT_INLINE void orbit_perf_end_request(uint64_t start_cycles) {
    uint64_t end = orbit_rdtsc();
    uint64_t duration = end - start_cycles;

    orbit_perf_record_latency(duration);
    orbit_perf_atomic_add64(&orbit_perf_stats.total_cycles, duration);

    // Minor race on min/max is acceptable for statistics compared to full CAS overhead
    if (duration < orbit_perf_stats.min_cycles || orbit_perf_stats.min_cycles == 0) {
        orbit_perf_stats.min_cycles = duration;
    }

    if (duration > orbit_perf_stats.max_cycles) {
        orbit_perf_stats.max_cycles = duration;
    }
}



ORBIT_INLINE OrbitPerfStats orbit_perf_get_stats(void) {
    return orbit_perf_stats;
}

/* 4xx and 5xx are errors; everything the server answers below that is ok.
 * Counted at the send path so the default router and the emitted one feed the
 * same pair. */
ORBIT_INLINE void orbit_perf_note_response(int status) {
    if (status >= 400) orbit_perf_atomic_inc64(&orbit_perf_stats.request_error);
    else orbit_perf_atomic_inc64(&orbit_perf_stats.request_ok);
}


/* ── Epochal VM Arena telemetry recording helpers ────────────────────── */

/* Join one arena's interval counters into the process totals. Called once
 * per request, from orbit_arena_reset, against four stores per allocation on
 * the old fast path: fewer shared writes, and exact, because an arena's
 * counters are private to the worker that owns it and an atomic add cannot
 * lose one. allocs/requested/aligned are what the arena accumulated since its
 * last reset; peak_used is the arena's own high-water mark, which reset does
 * not clear, so the same value is offered again on later resets. */
static inline void orbit_perf_fold_arena(uint64_t allocs, uint64_t requested,
                                         uint64_t aligned, uint64_t peak_used) {
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_alloc_count, allocs);
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_requested_bytes, requested);
    orbit_perf_atomic_add64(&orbit_perf_stats.arena_aligned_bytes, aligned);
    orbit_perf_atomic_add64(&orbit_perf_stats.total_alloc_bytes, aligned);
    orbit_perf_atomic_max64(&orbit_perf_stats.arena_peak_used_bytes, peak_used);
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
    /* Energy attribution (Kynx 0.1 C4): snapshots at creation, ESTIMATE
     * at destroy. Appended at the end so existing offsets never move. */
    uint64_t start_cycles;        /* orbit_rdtsc() at lease creation */
    uint64_t start_total_cycles;  /* perf total_cycles at creation (share basis) */
    double   start_joules;        /* attributable package joules at creation */
    double   joules;              /* attributed ESTIMATE, set at destroy (0 = proxy) */
} OrbitKynxLease;

/* The lease the current request runs under (NULL outside a Kynx request). Owned
 * by the counters' owner like orbit_perf_stats; arena.c reads it, kynx.c sets it. */
#ifdef ORBIT_PERF_IMPL
ORBIT_THREAD_LOCAL OrbitKynxLease* current_lease = NULL;
#elif defined(ORBIT_SEPARATE_COMPILATION) || defined(ORBIT_RUNTIME_MODULE)
extern ORBIT_THREAD_LOCAL OrbitKynxLease* current_lease;
#else
static ORBIT_THREAD_LOCAL OrbitKynxLease* current_lease = NULL;
#endif

#endif
