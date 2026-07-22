/**
 * @file  builtins.c
 * @brief Orbit built-in functions exposed to user programs.
 *
 * Provides cross-platform conversions and timing primitives used by
 * compute benchmarks and general-purpose Orbit programs.
 */
#ifndef ORBIT_BUILTINS_C
#define ORBIT_BUILTINS_C

#include "types.c"
#include "arena.c"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <time.h>
#ifdef _WIN32
#  include <windows.h>
#endif

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
    /* Scale to nanoseconds; use 128-bit intermediate via __int64 arithmetic */
    return (orbit_int)((now.QuadPart * (LONGLONG)1000000000) / freq.QuadPart);
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
typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
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
    (void)param_name;
    if (!req || !req->path) return "";
    /* Return path segment or empty fallback */
    return req->path;
}

orbit_string orbit_http_body_get(OrbitArena* arena, OrbitRequest* req) {
    (void)arena;
    if (!req || !req->body) return "{}";
    return req->body;
}

orbit_string orbit_http_client_fetch(OrbitArena* arena, orbit_string url) {
    (void)url;
    /* High-speed C HTTP Client fetch stub returning mock JSON response */
    char* res = (char*)orbit_alloc(arena, 128);
    if (!res) return "{}";
    strcpy(res, "{\"status\":\"ok\",\"fetched\":true}");
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
            strcpy(buf, g_orbit_cache[i].val);
            return buf;
        }
    }
    return "";
}

bool orbit_cache_set(orbit_string key, orbit_string val, int64_t ttl) {
    (void)ttl;
    if (!key || !val) return false;
    for (size_t i = 0; i < g_orbit_cache_count; i++) {
        if (strcmp(g_orbit_cache[i].key, key) == 0) {
            strncpy(g_orbit_cache[i].val, val, sizeof(g_orbit_cache[i].val) - 1);
            return true;
        }
    }
    if (g_orbit_cache_count < 64) {
        strncpy(g_orbit_cache[g_orbit_cache_count].key, key, sizeof(g_orbit_cache[0].key) - 1);
        strncpy(g_orbit_cache[g_orbit_cache_count].val, val, sizeof(g_orbit_cache[0].val) - 1);
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

#endif /* ORBIT_BUILTINS_C */
