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
#include "crt_compat.h"

/* The C that the Orbit compiler emits calls getenv() in its generated colour
 * preamble, and MSVC deprecates getenv, so a -Werror build on Windows fails
 * there and only there. The call is redirected here instead of in the emitted
 * text: sema already reserves the name getenv for user code (see sema.orb), so
 * no Orbit-visible behaviour can change, and the emitted C stays byte-identical
 * to what the committed parity goldens hash. Placed after crt_compat.h, whose
 * own getenv() call in the non-MSVC branch is therefore already expanded. */
#define getenv orbit_env_get

/* ── Separate compilation ─────────────────────────────────────────────
 * With -DORBIT_SEPARATE_COMPILATION this header exposes only the
 * declarations in orbit_api.h; the definitions live in libruntime_net.a
 * (see scripts/mklib_runtime.py). Without it this header is the unity
 * implementation, exactly as before. The emitted preamble is identical
 * in both modes; only this switch changes. */
#ifdef ORBIT_SEPARATE_COMPILATION
#include "orbit_api.h"
#else

/* ── Core types & Result<T,E> ──────────────────────────────────────── */
#include "types.c"
#include "inline.h"

/* ── Diagnostics ────────────────────────────────────────────────────── */
#include "performance.h"

/* ── Memory ─────────────────────────────────────────────────────────── */
#include "arena.c"
#include "arena_alloc.c"
#include "arena_oom.c"
#include "arena_reset.c"
#include "arena_checkpoint.c"
#include "arena_child.c"
#include "arena_stats.c"
#include "arena_global.c"
#include "arena_pool.c"
#include "string_pool.c"

/* ── Collections (List, Map) ───────────────────────────────────────── */
#include "collections.c"

/* ── Objects and JSON ───────────────────────────────────────────────── */
#include "json.c"

/* ── I/O ────────────────────────────────────────────────────────────── */
#include "file.c"
#include "os.c"

/* ── Built-in functions (conversions, clock) ───────────────────────── */
#include "builtins.c"
#include "console.c"
#include "crash.c"
#include "crypto.c"
#include "selfhost.c"

/* ── Energy sampler (Linux RAPL at 1 Hz; labeled CPU proxy elsewhere) ── */
#include "energy.c"

/* ── Cost ledger (per-route attribution, always on) ─────────────────── */
#include "ledger.c"

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
#include "pulse.c"
#endif

/* ── Convenience ────────────────────────────────────────────────────── */
#define print(...) do { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)

static inline int bit_op(int i) {
    return ((i * 17) ^ (i >> 2)) & 0xFFFF;
}

/* The unity build keeps the crash diagnostic armed before main, as it always
 * did (tests and hand-written C have no generated main). The generated main
 * also calls orbit_crash_handler_install(); installing twice is harmless. */
#ifdef _WIN32
static void __attribute__((constructor)) orbit_init_crash_handler(void) {
    orbit_crash_handler_install();
}
#endif

#endif /* ORBIT_SEPARATE_COMPILATION unity implementation */

#endif
