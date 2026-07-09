#ifndef ORBIT_RUNTIME_H
#define ORBIT_RUNTIME_H

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

/* ── Data ───────────────────────────────────────────────────────────── */
#include "database.c"

/* ── Auth (sessions/users, Bearer tokens) ──────────────────────────── */
#include "auth.c"


/* ── Network ────────────────────────────────────────────────────────── */
#include "http.c"

/* ── Security ───────────────────────────────────────────────────────── */
#include "kynx.c"

/* ── Convenience ────────────────────────────────────────────────────── */
#define print(...) do { printf(__VA_ARGS__); fflush(stdout); } while(0)

#endif
