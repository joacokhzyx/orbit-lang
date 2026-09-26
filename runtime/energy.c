/**
 * @file  energy.c
 * @brief Package-energy sampler (Linux RAPL/powercap) plus labeled CPU proxy.
 *
 * What this file does:
 * - On Linux with a readable powercap sensor, a background thread samples
 *   /sys/class/powercap energy_uj at 1 Hz, accumulates package joules, and
 *   calibrates an idle baseline from the first quiet seconds after start.
 * - On Windows, macOS, or Linux without a sensor, there is no thread and no
 *   joule value: orbit_energy_has_sensor() reads 0 and every joule accessor
 *   reads 0. Callers must label that path "cpu-proxy" and must never present
 *   cycle counters as joules.
 *
 * Attribution model (ESTIMATE, not a meter reading): the ledger assigns each
 * route a share of the attributable package energy proportional to its share
 * of handler cycles. Energy is not proportional to cycles under turbo, idle,
 * or IO wait, so per-route joules are an engineering estimate. See
 * docs/ENERGY.md. What is not measured is not shown: without a sensor the
 * ledger reports 0 joules and says proxy.
 *
 * Lifecycle: orbit_energy_start() is called from orbit_http_init() and
 * orbit_energy_stop() from orbit_http_cleanup(), so the sampler lives exactly
 * as long as the server. Both are idempotent. The sampler blocks in
 * nanosleep between reads (no busy loop) and stop() joins the thread, so
 * there is no leak and at most a 1 s join delay.
 *
 * RAPL note: energy_uj counters wrap at max_energy_range_uj. The sampler
 * reads that range once at start and applies it on wrap; when the range file
 * is absent it falls back to unsigned wrap arithmetic.
 */
#ifndef ORBIT_ENERGY_C
#define ORBIT_ENERGY_C

#include "performance.h"
#include "crt_compat.h"
#include <stdio.h>
#include <string.h>

#if defined(__linux__) && !defined(_WIN32)
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

/* Sensor candidates, most common layout first. */
#define ORBIT_ENERGY_CANDIDATE_0 "/sys/class/powercap/intel-rapl:0/energy_uj"
#define ORBIT_ENERGY_CANDIDATE_1 "/sys/class/powercap/intel-rapl:0:0/energy_uj"
#define ORBIT_ENERGY_CANDIDATE_2 "/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
#define ORBIT_ENERGY_IDLE_SAMPLES 5

static volatile int orbit_energy_running = 0;
static int orbit_energy_started = 0;
static int orbit_energy_sensor_ok = 0;
static char orbit_energy_sensor_path[256] = {0};
static uint64_t orbit_energy_total_uj = 0;
static uint64_t orbit_energy_max_range_uj = 0;
static uint64_t orbit_energy_start_ns = 0;
static double orbit_energy_idle_w = 0.0;
static int orbit_energy_cal_state = 0; /* 0 pending, 1 idle-calibrated, 2 loaded (gross) */
static uint64_t orbit_energy_idle_req0 = 0;

#if defined(__linux__) && !defined(_WIN32)
static pthread_t orbit_energy_thread;
static int orbit_energy_thread_live = 0;
/* Idle-window accumulators live here because only the Linux sampler thread
 * reads them; at file scope they would warn as set-but-unused elsewhere. */
static double orbit_energy_idle_win_j = 0.0;
static double orbit_energy_idle_win_s = 0.0;
static unsigned int orbit_energy_idle_nsamples = 0;
#endif

static uint64_t orbit_energy_now_ns(void) {
#if defined(_WIN32)
    return (uint64_t)GetTickCount64() * 1000000ULL;
#elif defined(CLOCK_MONOTONIC)
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#else
    return (uint64_t)time(0) * 1000000000ULL;
#endif
}

/* Read one unsigned counter from a sysfs file. Returns 1 on success. */
static int orbit_energy_read_uj(const char* path, uint64_t* out) {
    FILE* f = orbit_fopen(path, "r");
    char line[64];
    if (!f || !out) {
        if (f) fclose(f);
        return 0;
    }
    if (!fgets(line, sizeof(line), f)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    {
        /* strtoull rather than sscanf("%llu"): not deprecated on MSVC, and
         * "no digits consumed" is exactly what sscanf's != 1 was testing. */
        char* end = NULL;
        unsigned long long v = strtoull(line, &end, 10);
        if (end == line) return 0;
        *out = (uint64_t)v;
        return 1;
    }
}

/* Probe the known powercap paths. On success stores the working path and
 * its wrap range (0 when the range file is absent). Returns 1 with sensor. */
static int orbit_energy_probe(void) {
    static const char* cands[3] = {
        ORBIT_ENERGY_CANDIDATE_0,
        ORBIT_ENERGY_CANDIDATE_1,
        ORBIT_ENERGY_CANDIDATE_2
    };
    int i = 0;
    uint64_t v = 0;
    while (i < 3) {
        if (orbit_energy_read_uj(cands[i], &v)) {
            size_t n = strlen(cands[i]);
            if (n >= sizeof(orbit_energy_sensor_path)) return 0;
            memcpy(orbit_energy_sensor_path, cands[i], n + 1);
            /* Sibling max_energy_range_uj in the same directory. */
            {
                char range[256];
                const char* slash = strrchr(cands[i], '/');
                size_t dirlen = slash ? (size_t)(slash - cands[i]) : 0;
                if (dirlen + 22 < sizeof(range)) {
                    uint64_t r = 0;
                    memcpy(range, cands[i], dirlen);
                    memcpy(range + dirlen, "/max_energy_range_uj", 21);
                    range[dirlen + 21] = '\0';
                    if (orbit_energy_read_uj(range, &r) && r > 0) {
                        orbit_energy_max_range_uj = r;
                    }
                }
            }
            return 1;
        }
        i++;
    }
    return 0;
}

#if defined(__linux__) && !defined(_WIN32)
/* 1 Hz sampler. Blocks in nanosleep; exits promptly after stop (<=1 s). */
static void* orbit_energy_sampler(void* arg) {
    uint64_t prev = 0;
    int have_prev = 0;
    (void)arg;
    {
        uint64_t first = 0;
        if (!orbit_energy_read_uj(orbit_energy_sensor_path, &first)) return NULL;
        prev = first;
        have_prev = 1;
    }
    while (orbit_energy_running) {
        struct timespec req;
        uint64_t cur = 0;
        uint64_t t0 = orbit_energy_now_ns();
        req.tv_sec = 1;
        req.tv_nsec = 0;
        nanosleep(&req, NULL);
        if (!orbit_energy_running) break;
        if (!orbit_energy_read_uj(orbit_energy_sensor_path, &cur)) continue;
        {
            uint64_t delta = 0;
            double dt = 0.0;
            uint64_t t1 = orbit_energy_now_ns();
            if (cur >= prev) {
                delta = cur - prev;
            } else if (orbit_energy_max_range_uj > 0) {
                delta = (orbit_energy_max_range_uj - prev) + cur;
            } else {
                delta = cur; /* unsigned wrap fallback: count from zero */
            }
            prev = cur;
            dt = (double)(t1 - t0) / 1000000000.0;
            if (dt <= 0.0) dt = 1.0;
            orbit_perf_atomic_add64(&orbit_energy_total_uj, delta);
            if (orbit_energy_cal_state == 0) {
                /* Idle window: only quiet seconds count toward the baseline.
                 * When requests arrived before calibration finished, the box
                 * was never observed idle, so report gross energy (no
                 * subtraction) rather than subtracting load as "idle". */
                orbit_energy_idle_win_j += (double)delta / 1000000.0;
                orbit_energy_idle_win_s += dt;
                orbit_energy_idle_nsamples++;
                if (orbit_energy_idle_nsamples >= ORBIT_ENERGY_IDLE_SAMPLES) {
                    if (orbit_perf_stats.request_count == orbit_energy_idle_req0 &&
                        orbit_energy_idle_win_s > 0.0) {
                        orbit_energy_idle_w = orbit_energy_idle_win_j / orbit_energy_idle_win_s;
                        orbit_energy_cal_state = 1;
                    } else {
                        orbit_energy_idle_w = 0.0;
                        orbit_energy_cal_state = 2;
                    }
                }
            }
            (void)have_prev;
        }
    }
    return NULL;
}
#endif

/* Start the sampler. Idempotent; safe to call when no sensor exists. */
void orbit_energy_start(void) {
    if (orbit_energy_started) return;
    orbit_energy_started = 1;
    orbit_energy_start_ns = orbit_energy_now_ns();
    orbit_energy_idle_req0 = orbit_perf_stats.request_count;
#if defined(__linux__) && !defined(_WIN32)
    if (orbit_energy_probe()) {
        orbit_energy_sensor_ok = 1;
        orbit_energy_running = 1;
        if (pthread_create(&orbit_energy_thread, NULL, orbit_energy_sampler, NULL) == 0) {
            orbit_energy_thread_live = 1;
        } else {
            /* Thread failed: stay honest, report no live sampling. */
            orbit_energy_running = 0;
            orbit_energy_sensor_ok = 0;
            orbit_energy_sensor_path[0] = '\0';
        }
    }
#else
    /* Windows / macOS / sensor-less builds: labeled CPU proxy, no sampler. */
    orbit_energy_sensor_ok = 0;
    (void)orbit_energy_probe;
    (void)orbit_energy_read_uj;
#endif
}

/* Stop the sampler and join the thread. Idempotent. */
void orbit_energy_stop(void) {
    if (!orbit_energy_started) return;
#if defined(__linux__) && !defined(_WIN32)
    if (orbit_energy_thread_live) {
        orbit_energy_running = 0;
        pthread_join(orbit_energy_thread, NULL);
        orbit_energy_thread_live = 0;
    }
    orbit_energy_running = 0;
#endif
    orbit_energy_started = 0;
}

/* 1 when a live RAPL sampler backs the joule accessors, else 0. */
int orbit_energy_has_sensor(void) {
    return orbit_energy_sensor_ok;
}

/* "rapl-estimate" with a sensor, "cpu-proxy" without. Never empty. */
const char* orbit_energy_source(void) {
    return orbit_energy_sensor_ok ? "rapl-estimate" : "cpu-proxy";
}

/* Working sensor path, or "" when absent. For diagnostics only. */
const char* orbit_energy_sensor_path_str(void) {
    return orbit_energy_sensor_path;
}

/* Total sampled package joules since start. 0 without a sensor. */
double orbit_energy_total_joules(void) {
    if (!orbit_energy_sensor_ok) return 0.0;
    return (double)orbit_energy_total_uj / 1000000.0;
}

/* Calibrated idle watts, or 0 when uncalibrated / loaded / sensor-less. */
double orbit_energy_idle_watts(void) {
    if (!orbit_energy_sensor_ok || orbit_energy_cal_state != 1) return 0.0;
    return orbit_energy_idle_w;
}

/* Seconds since orbit_energy_start. 0 when never started. */
double orbit_energy_uptime_s(void) {
    uint64_t now;
    if (orbit_energy_start_ns == 0) return 0.0;
    now = orbit_energy_now_ns();
    if (now < orbit_energy_start_ns) return 0.0;
    return (double)(now - orbit_energy_start_ns) / 1000000000.0;
}

/* Package joules minus idle baseline, clamped at 0. ESTIMATE. */
double orbit_energy_attributable_joules(void) {
    double total = orbit_energy_total_joules();
    if (!orbit_energy_sensor_ok) return 0.0;
    if (orbit_energy_cal_state == 1) {
        double idle = orbit_energy_idle_w * orbit_energy_uptime_s();
        double net = total - idle;
        return net > 0.0 ? net : 0.0;
    }
    return total;
}

/* Route share of attributable joules by cycle share. ESTIMATE; 0 without sensor. */
double orbit_energy_route_joules(uint64_t route_cycles, uint64_t total_cycles) {
    double attr;
    double share;
    if (!orbit_energy_sensor_ok || total_cycles == 0) return 0.0;
    attr = orbit_energy_attributable_joules();
    share = (double)route_cycles / (double)total_cycles;
    if (share < 0.0) share = 0.0;
    if (share > 1.0) share = 1.0;
    return attr * share;
}

#endif
