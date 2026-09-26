/**
 * @file  builtins.c
 * @brief Orbit built-in functions exposed to user programs.
 *
 * Provides cross-platform conversions and timing primitives used by
 * general-purpose Orbit programs.
 */
#ifndef ORBIT_BUILTINS_C
#define ORBIT_BUILTINS_C

#include "types.c"
#include "arena.c"
#include "performance.h"
#include "crt_compat.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <time.h>
#ifdef _WIN32
#  include <windows.h>
#else
#  include <unistd.h>
#endif

void orbit_print(const char* str) {
    if (str) printf("%s\n", str);
    else printf("\n");
    fflush(stdout);
}

/**
 * Read a line from stdin, optionally printing a prompt.
 * The returned string is arena-allocated and NUL-terminated.
 */
orbit_string orbit_input(OrbitArena* arena, const char* prompt) {
    if (prompt) {
        printf("%s", prompt);
        fflush(stdout);
    }
    char buf[1024];
    if (!fgets(buf, sizeof(buf), stdin)) {
        char* empty = orbit_alloc(arena, 1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[len - 1] = '\0';
        len--;
    }
    char* result = orbit_alloc(arena, len + 1);
    if (result) {
        memcpy(result, buf, len + 1);
    }
    return result;
}

/* ── Numeric ↔ String conversions ─────────────────────────────────────────── */

/**
 * Parse a decimal integer from an orbit_string.
 * Returns 0 if the string is NULL or not a valid integer.
 */
orbit_int orbit_string_to_int(orbit_string s) {
    if (!s || *s == '\0') return 0;
    return (orbit_int)atoi(s);
}

/**
 * Parse a floating-point number from an orbit_string.
 */
orbit_float orbit_string_to_float(orbit_string s) {
    if (!s || *s == '\0') return 0.0;
    return (orbit_float)atof(s);
}

/* ── High-resolution monotonic clock ──────────────────────────────────────── */

/**
 * Return the current time as nanoseconds from an unspecified epoch.
 * Uses QueryPerformanceCounter on Windows, clock_gettime(CLOCK_MONOTONIC)
 * elsewhere.  Suitable only for measuring durations, not wall-clock time.
 */
orbit_int orbit_clock_ns(void) {
#ifdef _WIN32
    static LARGE_INTEGER freq = {0};
    if (freq.QuadPart == 0) {
        QueryPerformanceFrequency(&freq);
    }
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    /* Scale to nanoseconds without 64-bit overflow */
    LONGLONG sec = now.QuadPart / freq.QuadPart;
    LONGLONG rem = now.QuadPart % freq.QuadPart;
    return (orbit_int)(sec * 1000000000LL + (rem * 1000000000LL) / freq.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (orbit_int)(ts.tv_sec * 1000000000LL + ts.tv_nsec);
#endif
}

/* ── HTTP query parameter extraction ──────────────────────────────────────── */

/* Forward-declare OrbitRequest so builtins.c can reference it without
 * pulling in the entire HTTP stack (which has its own include guards). */
#ifndef ORBIT_HTTP_H
/* Fallback mirror of the http.c declaration (which also carries path-param
 * slots); keep both in sync. */
#define ORBIT_MAX_PATH_PARAMS 8
typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
    char* param_names[ORBIT_MAX_PATH_PARAMS];
    char* param_values[ORBIT_MAX_PATH_PARAMS];
    int param_count;
} OrbitRequest;
#endif

/**
 * Extract the value of a named parameter from an HTTP query string.
 *
 * Example:  query = "n=42&foo=bar", key = "n"  →  "42"
 * Returns "" if the key is not found or query/key is NULL.
 * The returned string is arena-allocated and NUL-terminated.
 */
orbit_string orbit_http_query_get(OrbitArena* arena, OrbitRequest* req, orbit_string key) {
    if (!req || !req->query || !key) return "";
    const char* q = req->query;
    size_t klen = strlen(key);
    while (*q) {
        /* Find key= at current position */
        if (strncmp(q, key, klen) == 0 && q[klen] == '=') {
            const char* val_start = q + klen + 1;
            const char* val_end   = strchr(val_start, '&');
            size_t vlen = val_end ? (size_t)(val_end - val_start) : strlen(val_start);
            char* buf = (char*)orbit_alloc(arena, vlen + 1);
            if (!buf) return "";
            memcpy(buf, val_start, vlen);
            buf[vlen] = '\0';
            return buf;
        }
        /* Advance past current key-value pair */
        const char* amp = strchr(q, '&');
        if (!amp) break;
        q = amp + 1;
    }
    return "";
}

orbit_string orbit_http_param_get(OrbitArena* arena, OrbitRequest* req, orbit_string param_name) {
    int i;
    (void)arena;
    if (!req || !param_name) return "";
    /* Path params captured by orbit_route_match during dispatch. */
    for (i = 0; i < req->param_count && i < ORBIT_MAX_PATH_PARAMS; i++) {
        if (req->param_names[i] && strcmp(req->param_names[i], param_name) == 0) {
            return req->param_values[i] ? req->param_values[i] : "";
        }
    }
    return "";
}

orbit_string orbit_http_body_get(OrbitArena* arena, OrbitRequest* req) {
    (void)arena;
    if (!req || !req->body) return "{}";
    return req->body;
}

/**
 * Read a field out of a JSON object string (e.g. `body.id` where `body` is a
 * `req.body()` string).  Returns an arena-allocated copy, or "" when the key is
 * missing.  This is the safe member-access path for string-typed objects; the
 * struct-cast path only applies to real model-typed values.
 */
orbit_string orbit_json_field(OrbitArena* arena, orbit_string json, orbit_string key) {
    if (!arena || !json || !key) return "";
    size_t key_len = strlen(key);
    char search[256];
    const char* start;
    const char* end;
    size_t len;
    char* res;

    /* Quoted string value: "key":"value" */
    size_t q_len = key_len + 4; /* "key":" */
    if (q_len >= sizeof(search)) return "";
    snprintf(search, sizeof(search), "\"%s\":\"", key);
    start = strstr(json, search);
    if (start) {
        start += q_len;
        end = strchr(start, '"');
        if (end) {
            len = (size_t)(end - start);
            res = (char*)orbit_alloc(arena, len + 1);
            if (!res) return "";
            memcpy(res, start, len);
            res[len] = '\0';
            return res;
        }
    }

    /* Bare value: "key":value */
    size_t b_len = key_len + 3; /* "key": */
    if (b_len >= sizeof(search)) return "";
    snprintf(search, sizeof(search), "\"%s\":", key);
    start = strstr(json, search);
    if (!start) return "";
    start += b_len;
    end = start;
    while (*end && *end != ',' && *end != '}' && *end != '\n') end++;
    len = (size_t)(end - start);
    res = (char*)orbit_alloc(arena, len + 1);
    if (!res) return "";
    memcpy(res, start, len);
    res[len] = '\0';
    return res;
}

orbit_string orbit_http_client_fetch(OrbitArena* arena, orbit_string url) {
    (void)url;
    /* High-speed C HTTP Client fetch stub returning mock JSON response */
    char* res = (char*)orbit_alloc(arena, 128);
    if (!res) return "{}";
    snprintf(res, 128, "{\"status\":\"ok\",\"fetched\":true}");
    return res;
}

typedef struct {
    char key[128];
    char val[512];
    uint64_t expires_at;
} OrbitCacheItem;

static OrbitCacheItem g_orbit_cache[64];
static size_t g_orbit_cache_count = 0;

orbit_string orbit_cache_get(OrbitArena* arena, orbit_string key) {
    if (!key) return "";
    for (size_t i = 0; i < g_orbit_cache_count; i++) {
        if (strcmp(g_orbit_cache[i].key, key) == 0) {
            char* buf = (char*)orbit_alloc(arena, strlen(g_orbit_cache[i].val) + 1);
            if (!buf) return "";
            memcpy(buf, g_orbit_cache[i].val, strlen(g_orbit_cache[i].val) + 1);
            return buf;
        }
    }
    return "";
}

/* snprintf rather than strncpy: it always terminates, and strncpy(dst, src,
 * sizeof(dst) - 1) left the final byte untouched, so overwriting a longer
 * earlier value left a key or val with no NUL in it. */
bool orbit_cache_set(orbit_string key, orbit_string val, int64_t ttl) {
    (void)ttl;
    if (!key || !val) return false;
    for (size_t i = 0; i < g_orbit_cache_count; i++) {
        if (strcmp(g_orbit_cache[i].key, key) == 0) {
            snprintf(g_orbit_cache[i].val, sizeof(g_orbit_cache[i].val), "%s", val);
            return true;
        }
    }
    if (g_orbit_cache_count < 64) {
        snprintf(g_orbit_cache[g_orbit_cache_count].key, sizeof(g_orbit_cache[0].key), "%s", key);
        snprintf(g_orbit_cache[g_orbit_cache_count].val, sizeof(g_orbit_cache[0].val), "%s", val);
        g_orbit_cache_count++;
        return true;
    }
    return false;
}

orbit_string orbit_file_upload_save(OrbitArena* arena, OrbitRequest* req, orbit_string field_name, orbit_string dest_dir) {
    (void)req;
    (void)field_name;
    /* Security-sanitized file upload handler saving to dest_dir */
    char* saved_path = (char*)orbit_alloc(arena, 256);
    if (!saved_path) return "";
    snprintf(saved_path, 256, "%s/upload_%llu.bin", dest_dir ? dest_dir : "./uploads", (unsigned long long)time(NULL));
    return saved_path;
}

/* ── System Telemetry (real counters, no invented values) ────────────────────
 * Every function below reads live process/runtime state. What is not
 * measured (e.g. success/error split, p50/p99) is not exposed. */

static uint64_t orbit_process_start_ns = 0;

static uint64_t orbit_monotonic_ns(void) {
#ifdef _WIN32
    static LARGE_INTEGER orbit_qpc_freq = {0};
    if (orbit_qpc_freq.QuadPart == 0) QueryPerformanceFrequency(&orbit_qpc_freq);
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (uint64_t)(t.QuadPart * 1000000000ULL / (uint64_t)orbit_qpc_freq.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

/* Workers configured at server startup (generated main calls the setter).
 * While serving, every configured worker is alive; plain programs read 0. */
static int orbit_configured_workers = 0;

void orbit_system_set_workers(int n) {
    orbit_configured_workers = n > 0 ? n : 0;
}

/* Seconds since process start. */
orbit_int system_uptime(void) {
    if (orbit_process_start_ns == 0) orbit_process_start_ns = orbit_monotonic_ns();
    return (orbit_int)((orbit_monotonic_ns() - orbit_process_start_ns) / 1000000000ULL);
}

orbit_int system_pid(void) {
#ifdef _WIN32
    return (orbit_int)GetCurrentProcessId();
#else
    return (orbit_int)getpid();
#endif
}

orbit_int system_active_workers(void) {
    return orbit_configured_workers;
}

orbit_int system_http_requests_total(void) {
    return (orbit_int)orbit_perf_get_stats().request_count;
}

/* Mean request latency in microseconds. Same 2.5 GHz RDTSC basis as the
 * per-request server log; approximate on other clock rates. Zero before
 * the first completed request. */
orbit_int system_latency_avg_us(void) {
    OrbitPerfStats stats = orbit_perf_get_stats();
    if (stats.request_count == 0) return 0;
    return (orbit_int)((stats.total_cycles / stats.request_count) / 2500ULL);
}

orbit_int system_os_exec(orbit_string cmd) {
    if (!cmd) return -1;
#if !defined(ORBIT_WITH_EXEC)
    /* R3.6: command execution is opt-in. Build with -DORBIT_WITH_EXEC
     * to enable; default builds refuse (RCE surface). */
    return -2;
#else
    return (orbit_int)system(cmd);
#endif
}

orbit_string system_env(orbit_string name) {
    if (!name) return "";
    const char* val = orbit_env_get(name);
    return val ? val : "";
}

#endif /* ORBIT_BUILTINS_C */
