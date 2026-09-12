/**
 * @file  bench-ledger-overhead.c
 * @brief Micro-benchmark for ledger enter/exit cost vs plain request parsing.
 *
 * Compiles against the Orbit C runtime as a single translation unit:
 *
 *   gcc -O2 -DORBIT_WITH_NET -I <repo-root> bench-ledger-overhead.c -o bench -lws2_32   (Windows)
 *   cc  -O2 -DORBIT_WITH_NET -I <repo-root> bench-ledger-overhead.c -o bench -lpthread  (Linux)
 *
 * Add -DORBIT_NO_LEDGER to compile the ledger hooks to no-ops and confirm
 * the flag path builds and reports empty ledgers.
 *
 * Each iteration parses a fixed GET request (fresh scratch copy, arena reset
 * afterwards, matching per-request arena reuse). The "with" loop wraps the
 * parse in orbit_ledger_enter/exit exactly like generated routers do; the
 * "without" loop parses only. Both wall time (ns/req) and RDTSC cycles/req
 * are reported as medians over internal rounds. Stdout is one JSON object.
 */
#include <stdio.h>
#include <string.h>

#include "runtime/runtime.h"

#ifdef _WIN32
static double bench_now_ns(void) {
    static LARGE_INTEGER freq = {0};
    LARGE_INTEGER c;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000000000.0 / (double)freq.QuadPart;
}
#else
#include <time.h>
static double bench_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000000000.0 + (double)ts.tv_nsec;
}
#endif

static const char bench_raw[] =
    "GET /hello?name=world HTTP/1.1\r\n"
    "Host: localhost\r\n"
    "Connection: keep-alive\r\n"
    "\r\n";

#define BENCH_ROUNDS 7
#define BENCH_ITERS 50000

static double bench_median(double* v, int n) {
    int i = 0;
    int j = 0;
    while (i < n) {
        j = i + 1;
        while (j < n) {
            if (v[j] < v[i]) {
                double t = v[i];
                v[i] = v[j];
                v[j] = t;
            }
            j++;
        }
        i++;
    }
    if (n % 2 == 1) return v[n / 2];
    return (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

int main(void) {
    OrbitArena* arena = NULL;
    char scratch[512];
    double with_ns[BENCH_ROUNDS];
    double without_ns[BENCH_ROUNDS];
    double with_cy[BENCH_ROUNDS];
    double without_cy[BENCH_ROUNDS];
    size_t raw_len = strlen(bench_raw);
    int r = 0;

    orbit_http_init();
    arena = orbit_arena_create(131072);
    if (!arena) {
        printf("{\"error\":\"arena unavailable\"}\n");
        return 1;
    }

    /* Warm-up so caches and branch predictors settle before measuring. */
    {
        int w = 0;
        while (w < 20000) {
            OrbitRequest* req = NULL;
            memcpy(scratch, bench_raw, raw_len + 1);
            orbit_http_parse_request(arena, scratch, raw_len, &req);
            orbit_arena_reset(arena);
            w++;
        }
    }

    r = 0;
    while (r < BENCH_ROUNDS) {
        int i = 0;
        double t0 = bench_now_ns();
        uint64_t c0 = orbit_rdtsc();
        i = 0;
        while (i < BENCH_ITERS) {
            OrbitRequest* req = NULL;
            uint64_t ls = 0;
            int slot = 0;
            memcpy(scratch, bench_raw, raw_len + 1);
            ls = orbit_rdtsc();
            slot = orbit_ledger_enter("GET", "/hello");
            orbit_http_parse_request(arena, scratch, raw_len, &req);
            if (req && req->path) { (void)req->path[0]; }
            orbit_ledger_exit(slot, orbit_rdtsc() - ls);
            orbit_arena_reset(arena);
            i++;
        }
        with_ns[r] = (bench_now_ns() - t0) / (double)BENCH_ITERS;
        with_cy[r] = (double)(orbit_rdtsc() - c0) / (double)BENCH_ITERS;

        t0 = bench_now_ns();
        c0 = orbit_rdtsc();
        i = 0;
        while (i < BENCH_ITERS) {
            OrbitRequest* req = NULL;
            memcpy(scratch, bench_raw, raw_len + 1);
            orbit_http_parse_request(arena, scratch, raw_len, &req);
            if (req && req->path) { (void)req->path[0]; }
            orbit_arena_reset(arena);
            i++;
        }
        without_ns[r] = (bench_now_ns() - t0) / (double)BENCH_ITERS;
        without_cy[r] = (double)(orbit_rdtsc() - c0) / (double)BENCH_ITERS;
        r++;
    }

    printf("{\"rounds\":%d,\"iters\":%d,"
           "\"with_ns_per_req\":%.1f,\"without_ns_per_req\":%.1f,"
           "\"with_cycles_per_req\":%.0f,\"without_cycles_per_req\":%.0f,"
           "\"no_ledger_build\":"
#ifdef ORBIT_NO_LEDGER
           "true"
#else
           "false"
#endif
           "}\n",
        BENCH_ROUNDS, BENCH_ITERS,
        bench_median(with_ns, BENCH_ROUNDS), bench_median(without_ns, BENCH_ROUNDS),
        bench_median(with_cy, BENCH_ROUNDS), bench_median(without_cy, BENCH_ROUNDS));

    orbit_arena_destroy(arena);
    orbit_http_cleanup();
    return 0;
}
