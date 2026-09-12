/**
 * @file  ledger.c
 * @brief Automatic per-route cost ledger for Orbit servers.
 *
 * No annotations, no config: the generated router records every handler
 * invocation (cycles) and every DB call (cycles, via a thread-local slot)
 * into a fixed table keyed by METHOD + route template. Served at /_ledger
 * (HTML, auto-refresh) and /_ledger/data (JSON). Loopback only.
 *
 * Honesty notes: cycles use the same 2.5 GHz RDTSC basis as the request
 * log, so milliseconds are approximate on other clocks. Energy in joules
 * is NOT reported here (no sensor wired yet); see the energy sampler
 * roadmap item. What is not measured is not shown.
 */
#ifndef ORBIT_LEDGER_C
#define ORBIT_LEDGER_C

#include "performance.h"
#include <stdio.h>
#include <string.h>

#define ORBIT_LEDGER_MAX 64

typedef struct {
    char method[16];
    char path[256];
    uint64_t count;
    uint64_t total_cycles;
    uint64_t db_cycles;
    int used;
} OrbitLedgerEntry;

static OrbitLedgerEntry orbit_ledger_table[ORBIT_LEDGER_MAX];
static uint64_t orbit_ledger_overflow = 0;

static ORBIT_THREAD_LOCAL int orbit_ledger_tls_slot = -1;

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
static int orbit_ledger_enter(const char* method, const char* path) {
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
}

static void orbit_ledger_exit(int idx, uint64_t cycles) {
    if (idx >= 0 && idx < ORBIT_LEDGER_MAX) {
        orbit_perf_atomic_inc64(&orbit_ledger_table[idx].count);
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].total_cycles, cycles);
    }
    orbit_ledger_tls_slot = -1;
}

/* DB timing choke points. Called from orbit_db_* entry functions. */
static inline uint64_t orbit_ledger_db_begin(void) {
    return orbit_rdtsc();
}

static inline void orbit_ledger_db_end(uint64_t t0) {
    int idx = orbit_ledger_tls_slot;
    if (idx >= 0 && idx < ORBIT_LEDGER_MAX) {
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].db_cycles, orbit_rdtsc() - t0);
    }
}

static int orbit_ledger_is_loopback(orbit_socket_t s) {
    struct sockaddr_storage ss;
    socklen_t len = (socklen_t)sizeof(ss);
    if (getpeername(s, (struct sockaddr*)&ss, &len) != 0) return 0;
    if (ss.ss_family == AF_INET) {
        struct sockaddr_in* in4 = (struct sockaddr_in*)&ss;
        return in4->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
    }
#ifdef AF_INET6
    if (ss.ss_family == AF_INET6) {
        struct sockaddr_in6* in6 = (struct sockaddr_in6*)&ss;
        return IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr);
    }
#endif
    return 0;
}

orbit_string orbit_ledger_json(OrbitArena* arena) {
    char* buf = (char*)orbit_alloc(arena, 16384);
    if (!buf) return "{\"routes\":[]}";
    size_t off = 0;
    off += (size_t)snprintf(buf + off, 16384 - off, "{\"routes\":[");
    int first = 1;
    int i = 0;
    while (i < ORBIT_LEDGER_MAX && off < 15000) {
        if (orbit_ledger_table[i].used) {
            uint64_t n = orbit_ledger_table[i].count;
            uint64_t tot = orbit_ledger_table[i].total_cycles;
            uint64_t db = orbit_ledger_table[i].db_cycles;
            uint64_t avg_c = n > 0 ? tot / n : 0;
            /* ms with 2 decimals on the 2.5 GHz basis (approximate). */
            uint64_t ms_i = avg_c / 2500000ULL;
            uint64_t ms_f = ((avg_c % 2500000ULL) * 100ULL) / 2500000ULL;
            uint64_t share = tot > 0 ? (db * 100ULL) / tot : 0;
            off += (size_t)snprintf(buf + off, 16384 - off,
                "%s{\"method\":\"%s\",\"path\":\"%s\",\"req\":%llu,\"avg_ms\":%llu.%02llu,\"db_share\":%llu}",
                first ? "" : ",",
                orbit_ledger_table[i].method, orbit_ledger_table[i].path,
                (unsigned long long)n,
                (unsigned long long)ms_i, (unsigned long long)ms_f,
                (unsigned long long)share);
            first = 0;
        }
        i++;
    }
    snprintf(buf + off, 16384 - off,
        "],\"note\":\"cycles on 2.5 GHz RDTSC basis; ms approximate. Joules not measured yet.\"}");
    return buf;
}

orbit_string orbit_ledger_html(OrbitArena* arena) {
    char* buf = (char*)orbit_alloc(arena, 24576);
    if (!buf) return "<html><body>ledger unavailable</body></html>";
    size_t off = 0;
    off += (size_t)snprintf(buf + off, 24576 - off,
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta http-equiv=\"refresh\" content=\"2\">"
        "<title>Orbit ledger</title></head>"
        "<body style=\"font-family:sans-serif;background:#f7f6f2;color:#111;margin:40px\">"
        "<h1>Cost ledger</h1>"
        "<p>Per-route handler cost. No annotations were written for this.</p>"
        "<table border=\"1\" cellpadding=\"8\" cellspacing=\"0\">"
        "<tr><th>Route</th><th>Req</th><th>Avg ms</th><th>DB share</th></tr>");
    int i = 0;
    while (i < ORBIT_LEDGER_MAX && off < 23000) {
        if (orbit_ledger_table[i].used) {
            uint64_t n = orbit_ledger_table[i].count;
            uint64_t tot = orbit_ledger_table[i].total_cycles;
            uint64_t db = orbit_ledger_table[i].db_cycles;
            uint64_t avg_c = n > 0 ? tot / n : 0;
            uint64_t ms_i = avg_c / 2500000ULL;
            uint64_t ms_f = ((avg_c % 2500000ULL) * 100ULL) / 2500000ULL;
            uint64_t share = tot > 0 ? (db * 100ULL) / tot : 0;
            off += (size_t)snprintf(buf + off, 24576 - off,
                "<tr><td>%s %s</td><td>%llu</td><td>%llu.%02llu</td><td>%llu%%</td></tr>",
                orbit_ledger_table[i].method, orbit_ledger_table[i].path,
                (unsigned long long)n,
                (unsigned long long)ms_i, (unsigned long long)ms_f,
                (unsigned long long)share);
        }
        i++;
    }
    snprintf(buf + off, 24576 - off,
        "</table>"
        "<p><small>Cycles on 2.5 GHz RDTSC basis; ms approximate. Joules not measured yet.</small></p>"
        "</body></html>");
    return buf;
}

#endif
