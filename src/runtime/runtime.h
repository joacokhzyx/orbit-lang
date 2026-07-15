/**
 * @file  runtime.h
 * @brief Top-level aggregation header for the Orbit C runtime.
 *
 * Pulls in platform compatibility shims, the arena allocator, HTTP layer,
 * database bindings, collections, auth, Kynx leases, and Pulse counters.
 * Generated Orbit programs include only this single header.
 */
#ifndef ORBIT_RUNTIME_H
#define ORBIT_RUNTIME_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Runtime — Unified header. Phase 2: Type Resonance.
 *
 * Include order matters: types → inline → arena → arena_pool →
 * string_pool → collections → performance → file → database → http → kynx
 *
 * Each subsystem is self-contained: init → use → cleanup.
 * All operations return OrbitResult where failure is possible.
 * ────────────────────────────────────────────────────────────────────── */

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <stdint.h>
#include "socket_compat.h"

/* ── Core types & Result<T,E> ──────────────────────────────────────── */
#include "types.c"
#include "inline.h"

/* ── Diagnostics ────────────────────────────────────────────────────── */
#include "performance.h"

/* ── Memory ─────────────────────────────────────────────────────────── */
#include "arena.c"
#include "arena_pool.c"
#include "string_pool.c"

/* ── Collections (List, Map) ───────────────────────────────────────── */
#include "collections.c"

/* ── I/O ────────────────────────────────────────────────────────────── */
#include "file.c"
#include "os.c"

/* ── Built-in functions (conversions, clock) ───────────────────────── */
#include "builtins.c"

/* ── Data ───────────────────────────────────────────────────────────── */
#ifndef ORBIT_CUSTOM_ROUTER
int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed);
#endif
#ifdef ORBIT_WITH_DB
#include "database.c"
#endif

/* ── Auth (sessions/users, Bearer tokens) ──────────────────────────── */
#ifdef ORBIT_WITH_DB
#include "auth.c"
#endif


/* ── Network ────────────────────────────────────────────────────────── */
#ifdef ORBIT_WITH_NET
#include "http.c"
#include "kynx.c"
#endif

/* ── Convenience ────────────────────────────────────────────────────── */
#define print(...) do { printf(__VA_ARGS__); } while(0)

static inline int bit_op(int i) {
    return ((i * 17) ^ (i >> 2)) & 0xFFFF;
}

#endif
