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

#ifdef _WIN32
#  include <windows.h>
#else
#  include <time.h>
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

#endif /* ORBIT_BUILTINS_C */
