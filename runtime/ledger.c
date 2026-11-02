#ifndef ORBIT_RT_LEDGER_C
#define ORBIT_RT_LEDGER_C

#include "module_prelude.h"
#include "ledger.h"
#include "types.h"
#include "arena.h"
#include "os.h"
#include "selfhost.h"
#include "energy.h"
#include "kynx.h"
#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#ifndef __ATOMIC_RELAXED
#endif
#endif
#endif
#include "performance.h"
#include <stdio.h>
#include <string.h>

OrbitLedgerEntry orbit_ledger_table[ORBIT_LEDGER_MAX];
static uint64_t orbit_ledger_overflow = 0;

ORBIT_THREAD_LOCAL int orbit_ledger_tls_slot = -1;

static int orbit_ledger_find(const char* method, const char* path) {
    int i = 0;
    while (i < ORBIT_LEDGER_MAX) {
        if (orbit_ledger_table[i].used) {
            if (strncmp(orbit_ledger_table[i].method, method ? method : "", 15) == 0 &&
                strncmp(orbit_ledger_table[i].path, path ? path : "", 255) == 0) {
                return i;
            }
        }
        i++;
    }
    return -1;
}

/* Claim a free slot for a new route key. Returns index or -1 when full. */
static int orbit_ledger_claim(const char* method, const char* path) {
    int i = 0;
    while (i < ORBIT_LEDGER_MAX) {
#ifdef _WIN32
        if (InterlockedCompareExchange((volatile LONG*)&orbit_ledger_table[i].used, 1, 0) == 0) {
#else
        if (__sync_bool_compare_and_swap(&orbit_ledger_table[i].used, 0, 1)) {
#endif
            size_t mi = 0;
            while (mi < 15 && method && method[mi]) {
                orbit_ledger_table[i].method[mi] = method[mi];
                mi++;
            }
            orbit_ledger_table[i].method[mi] = '\0';
            size_t pi = 0;
            while (pi < 255 && path && path[pi]) {
                orbit_ledger_table[i].path[pi] = path[pi];
                pi++;
            }
            orbit_ledger_table[i].path[pi] = '\0';
            return i;
        }
        i++;
    }
    return -1;
}

/* Called by generated code around each handler. Returns the slot index. */
int orbit_ledger_enter(const char* method, const char* path) {
#ifdef ORBIT_NO_LEDGER
    (void)method;
    (void)path;
    orbit_ledger_tls_slot = -1;
    return -1;
#else
    int idx = orbit_ledger_find(method, path);
    if (idx < 0) {
        idx = orbit_ledger_claim(method, path);
        if (idx < 0) {
            orbit_perf_atomic_inc64(&orbit_ledger_overflow);
            orbit_ledger_tls_slot = -1;
            return -1;
        }
    }
    orbit_ledger_tls_slot = idx;
    return idx;
#endif
}

/* Bucket index for a duration: the position of its highest set bit. */
static int orbit_ledger_lat_bucket(uint64_t cycles) {
    int b = 0;
    uint64_t c = cycles;
    while (c > 1) {
        c >>= 1;
        b++;
    }
    if (b >= ORBIT_LEDGER_LAT_BUCKETS) b = ORBIT_LEDGER_LAT_BUCKETS - 1;
    return b;
}

/* Percentile of one route, estimated inside the bucket that holds the rank, in
 * microseconds on the 2.5 GHz basis. per_mille is 500/950/990.
 *
 * Bucket i spans 2^i to 2^(i+1) cycles, and its two edges say only that the
 * value lies between them -- the answer used to be the top edge, so a route's
 * p99 was a power of two, never a measurement. The bucket also sums the cycles
 * it received, so the estimate anchors on that mean and spreads by rank, the
 * same rule `orbit_perf_percentile_us` uses for the whole server: mean plus
 * width times (rank minus half) over the count, clamped to the bucket. One
 * request in a bucket answers that request. */
static uint64_t orbit_ledger_percentile_us(const OrbitLedgerEntry* e, uint64_t per_mille) {
    if (e->count == 0) return 0;
    if (per_mille > 1000) per_mille = 1000;
    uint64_t target = (e->count * per_mille + 999) / 1000;
    uint64_t seen = 0;
    int i = 0;
    while (i < ORBIT_LEDGER_LAT_BUCKETS) {
        uint64_t in_bucket = e->lat[i];
        seen += in_bucket;
        if (seen >= target) {
            if (in_bucket == 0) return 0;
            uint64_t mean = e->lat_sum[i] / in_bucket;
            /* The last bucket is the clamp: it has no upper edge of its own,
             * because 2^64 cycles is not a number this table can hold, and its
             * mean is a measurement all the same. */
            if (i == ORBIT_LEDGER_LAT_BUCKETS - 1) return mean / 2500ULL;
            uint64_t lo = 1ULL << i;
            uint64_t hi = 1ULL << (i + 1);
            uint64_t rank = target - (seen - in_bucket);
            /* |num| <= in_bucket, so dividing the width by the count first keeps
             * the product under the width itself: no overflow at any request
             * count, at the cost of under one cycle per rank step. */
            int64_t num = (int64_t)(2 * rank - 1) - (int64_t)in_bucket;
            uint64_t step = (hi - lo) / in_bucket;
            int64_t est = (int64_t)mean;
            if (num >= 0) est += (int64_t)(step * (uint64_t)num);
            else est -= (int64_t)(step * (uint64_t)(-num));
            if (est < (int64_t)lo) return lo / 2500ULL;
            if ((uint64_t)est > hi) return hi / 2500ULL;
            return (uint64_t)est / 2500ULL;
        }
        i++;
    }
    /* Unreachable while every recorded duration lands in a bucket; kept so a
     * future bucket-count change cannot read past the array. */
    return 0;
}

/* Closes one request: the row's latency, and its memory when the caller can
 * say which arena the request ran in. @p arena is NULL for callers that do not
 * have one (tests, a demo server), which leaves the memory columns untouched. */
void orbit_ledger_exit(int idx, uint64_t cycles, const OrbitArena* arena) {
    /* Under ORBIT_NO_LEDGER, enter always returns -1, so this is a no-op
     * store apart from clearing the thread-local slot. */
    if (idx >= 0 && idx < ORBIT_LEDGER_MAX) {
        orbit_perf_atomic_inc64(&orbit_ledger_table[idx].count);
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].total_cycles, cycles);
        int lat_bucket = orbit_ledger_lat_bucket(cycles);
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].lat[lat_bucket], 1);
        /* The cycles this bucket received, so a percentile inside it has a
         * measurement to sit on rather than only an edge above it. */
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].lat_sum[lat_bucket], cycles);
        /* Memory of the request this row just closed, read from the arena the
         * request ran in: max_bytes is the footprint when the handler
         * returned, and a second segment means it overflowed. Both are
         * measured here rather than predicted. */
        orbit_perf_atomic_max64(&orbit_ledger_table[idx].max_bytes,
                                (uint64_t)orbit_arena_active_bytes(arena));
        if (orbit_arena_overflowed(arena)) {
            orbit_perf_atomic_inc64(&orbit_ledger_table[idx].overflow_count);
        }
    }
    orbit_ledger_tls_slot = -1;
}

/* Sum of handler cycles across used entries: denominator for joule shares. */
static uint64_t orbit_ledger_sum_cycles(void) {
    uint64_t sum = 0;
    int i = 0;
    while (i < ORBIT_LEDGER_MAX) {
        if (orbit_ledger_table[i].used) sum += orbit_ledger_table[i].total_cycles;
        i++;
    }
    return sum;
}
#ifdef ORBIT_ENERGY_C
#else
#endif

/**
 * Write the ledger to $ORBIT_LEDGER_OUT, once, at process exit.
 *
 * The telemetry exists only behind an HTTP endpoint on loopback, which means a
 * static analyser cannot read it: it would have to start a server, drive it with
 * traffic and know when to stop. That is why the production evidence this
 * runtime collects was, until now, unreachable from a tool.
 *
 * Written from an atexit hook rather than on demand because the interesting
 * cases are the ones a running service has seen and a fresh process has not --
 * "this route has never been requested" is only knowable after the service has
 * been up. The file is written atomically via a temporary and a rename, so a
 * reader never sees a half-written snapshot.
 *
 * Off unless ORBIT_LEDGER_OUT names a path. Zero cost when unset.
 */
static char orbit_ledger_out_path[512] = {0};

static void orbit_ledger_dump_at_exit(void) {
    if (orbit_ledger_out_path[0] == '\0') return;
    orbit_string json = orbit_ledger_json(orbit_arena_get_global());
    if (!json) return;

    char tmp[544];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp", orbit_ledger_out_path);
    if (n <= 0 || (size_t)n >= sizeof(tmp)) return;

    FILE* f = orbit_fopen(tmp, "wb");
    if (!f) return;
    size_t len = strlen(json);
    size_t wrote = len ? fwrite(json, 1, len, f) : 0;
    fflush(f);
    fclose(f);
    if (wrote != len) {
        remove(tmp);
        return;
    }
    /* rename() is the atomic step: a reader sees the old snapshot or the new
     * one, never a truncated one. */
    if (rename(tmp, orbit_ledger_out_path) != 0) remove(tmp);
}

/* Public, so the generated main() can arm it from the environment alone. */
void orbit_ledger_enable_file_dump(void) {
    const char* p = orbit_os_env(orbit_arena_get_global(), "ORBIT_LEDGER_OUT");
    if (!p || !*p) return;
    size_t n = strlen(p);
    if (n >= sizeof(orbit_ledger_out_path)) return;
    memcpy(orbit_ledger_out_path, p, n + 1);
    /* Once. A second call from another entry point would register a second
     * atexit hook and write the same file twice. */
    static int registered = 0;
    if (registered) return;
    registered = 1;
    atexit(orbit_ledger_dump_at_exit);
}

orbit_string orbit_ledger_json(OrbitArena* arena) {
    char* buf = (char*)orbit_alloc(arena, 32768);
    const char* src = ORBIT_LEDGER_SOURCE();
    const char* note = ORBIT_LEDGER_NOTE_PROXY;
    uint64_t denom = 0;
    if (!buf) return "{\"routes\":[]}";
    if (src[0] == 'r') note = ORBIT_LEDGER_NOTE_METERED; /* "rapl-estimate" */
    denom = orbit_ledger_sum_cycles();
    size_t off = 0;
    off += (size_t)snprintf(buf + off, 32768 - off, "{\"routes\":[");
    int first = 1;
    int i = 0;
    while (i < ORBIT_LEDGER_MAX && off < 31000) {
        if (orbit_ledger_table[i].used) {
            uint64_t n = orbit_ledger_table[i].count;
            uint64_t tot = orbit_ledger_table[i].total_cycles;
            uint64_t db = orbit_ledger_table[i].db_cycles;
            uint64_t avg_c = n > 0 ? tot / n : 0;
            /* ms with 2 decimals on the 2.5 GHz basis (approximate). */
            uint64_t ms_i = avg_c / 2500000ULL;
            uint64_t ms_f = ((avg_c % 2500000ULL) * 100ULL) / 2500000ULL;
            uint64_t share = tot > 0 ? (db * 100ULL) / tot : 0;
            double rj = ORBIT_LEDGER_ROUTE_J(tot, denom);
            double jpr = n > 0 ? rj / (double)n : 0.0;
            uint64_t p50 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 500);
            uint64_t p95 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 950);
            uint64_t p99 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 990);
            /* Memory of this route's requests, recorded by orbit_ledger_exit
             * from the arena each request ran in. max_bytes is the largest
             * footprint at handler return; overflow_count counts requests
             * that needed a second arena segment. Both are measured, so a
             * non-zero overflow is a request the arena could not hold. */
            uint64_t overflow = orbit_ledger_table[i].overflow_count;
            uint64_t max_bytes = orbit_ledger_table[i].max_bytes;
            off += (size_t)snprintf(buf + off, 32768 - off,
                "%s{\"method\":\"%s\",\"path\":\"%s\",\"req\":%llu,\"avg_ms\":%llu.%02llu,"
                "\"db_share\":%llu,\"joules_total\":%.6f,\"joules_per_req\":%.6f,"
                "\"avg_cycles\":%llu,\"p50_us\":%llu,\"p95_us\":%llu,\"p99_us\":%llu,"
                "\"arena_overflow\":%llu,\"arena_max_bytes\":%llu,"
                "\"latency_source\":\"%s\",\"energy_source\":\"%s\"}",
                first ? "" : ",",
                orbit_ledger_table[i].method, orbit_ledger_table[i].path,
                (unsigned long long)n,
                (unsigned long long)ms_i, (unsigned long long)ms_f,
                (unsigned long long)share,
                rj, jpr,
                (unsigned long long)avg_c,
                (unsigned long long)p50, (unsigned long long)p95, (unsigned long long)p99,
                (unsigned long long)overflow, (unsigned long long)max_bytes,
                "log2-bucket estimates, 2.5 GHz basis",
                src);
            first = 0;
        }
        i++;
    }
    snprintf(buf + off, 32768 - off,
        "],\"energy_source\":\"%s\",\"energy_note\":\"%s\"}", src, note);
    return buf;
}

orbit_string orbit_ledger_html(OrbitArena* arena) {
    char* buf = (char*)orbit_alloc(arena, 32768);
    const char* src = ORBIT_LEDGER_SOURCE();
    const char* note = ORBIT_LEDGER_NOTE_PROXY;
    uint64_t denom = 0;
    if (!buf) return "<html><body>ledger unavailable</body></html>";
    if (src[0] == 'r') note = ORBIT_LEDGER_NOTE_METERED;
    denom = orbit_ledger_sum_cycles();
    size_t off = 0;
    off += (size_t)snprintf(buf + off, 32768 - off,
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta http-equiv=\"refresh\" content=\"2\">"
        "<title>Orbit ledger</title></head>"
        "<body style=\"font-family:sans-serif;background:#f7f6f2;color:#111;margin:40px\">"
        "<h1>Cost ledger</h1>"
        "<p>Per-route handler cost. No annotations were written for this.</p>"
        "<table border=\"1\" cellpadding=\"8\" cellspacing=\"0\">"
        "<tr><th>Route</th><th>Req</th><th>Avg ms</th><th>p50 µs</th><th>p95 µs</th>"
        "<th>p99 µs</th><th>DB share</th>"
        "<th>Energy</th><th>Source</th></tr>");
    int i = 0;
    while (i < ORBIT_LEDGER_MAX && off < 31000) {
        if (orbit_ledger_table[i].used) {
            uint64_t n = orbit_ledger_table[i].count;
            uint64_t tot = orbit_ledger_table[i].total_cycles;
            uint64_t db = orbit_ledger_table[i].db_cycles;
            uint64_t avg_c = n > 0 ? tot / n : 0;
            uint64_t ms_i = avg_c / 2500000ULL;
            uint64_t ms_f = ((avg_c % 2500000ULL) * 100ULL) / 2500000ULL;
            uint64_t share = tot > 0 ? (db * 100ULL) / tot : 0;
            double rj = ORBIT_LEDGER_ROUTE_J(tot, denom);
            double jpr = n > 0 ? rj / (double)n : 0.0;
            uint64_t p50 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 500);
            uint64_t p95 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 950);
            uint64_t p99 = orbit_ledger_percentile_us(&orbit_ledger_table[i], 990);
            if (src[0] == 'r') {
                off += (size_t)snprintf(buf + off, 32768 - off,
                    "<tr><td>%s %s</td><td>%llu</td><td>%llu.%02llu</td><td>%llu</td>"
                    "<td>%llu</td><td>%llu</td><td>%llu%%</td>"
                    "<td>%.6f J/req (est.)</td><td>%s</td></tr>",
                    orbit_ledger_table[i].method, orbit_ledger_table[i].path,
                    (unsigned long long)n,
                    (unsigned long long)ms_i, (unsigned long long)ms_f,
                    (unsigned long long)p50, (unsigned long long)p95, (unsigned long long)p99,
                    (unsigned long long)share,
                    jpr, src);
            } else {
                off += (size_t)snprintf(buf + off, 32768 - off,
                    "<tr><td>%s %s</td><td>%llu</td><td>%llu.%02llu</td><td>%llu</td>"
                    "<td>%llu</td><td>%llu</td><td>%llu%%</td>"
                    "<td>&mdash; (cpu proxy: %llu cycles/req)</td><td>%s</td></tr>",
                    orbit_ledger_table[i].method, orbit_ledger_table[i].path,
                    (unsigned long long)n,
                    (unsigned long long)ms_i, (unsigned long long)ms_f,
                    (unsigned long long)p50, (unsigned long long)p95, (unsigned long long)p99,
                    (unsigned long long)share,
                    (unsigned long long)avg_c, src);
            }
        }
        i++;
    }
    snprintf(buf + off, 32768 - off,
        "</table>"
        "<p><small>Per-route percentiles are log2-bucket estimates on the 2.5 GHz "
        "basis, estimated inside each bucket from its own mean. %s "
        "Metered: RAPL package joules sampled at 1 Hz minus idle baseline. "
        "Estimated: per-route split by cycle share. Proxy: cycle counters where no sensor exists; "
        "never converted to joules.</small></p>"
        "</body></html>", note);
    return buf;
}

#endif
