/* Interface of runtime/admission.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_ADMISSION_H
#define ORBIT_RT_ADMISSION_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"
/**
 * @file  admission.c
 * @brief Sovereign Computational Control Layer for Orbit's request pipeline.
 *
 * Implements O(1) sharded admission control with per-IP rate limiting and
 * suspicion scoring, monotonic-clock deadline enforcement, and Computational
 * Leases that cap CPU time, arena memory, DB queries, and response size per
 * request.  Admission state transitions (Stable → Shaped → Guarded → Siege)
 * automatically tighten resource budgets as active-lease pressure grows.
 */
#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#define ORBIT_TINYC_SHIM
/* tcc judge build is single-thread-only: tcc provides no __thread TLS and no
 * __atomic_* builtins, so __thread degrades to a plain global and the builtins
 * degrade to plain operations. Never #undef'd: the unity TU shares one
 * preprocessor state, so every declaration and definition must agree (all
 * plain). Invisible to gcc/clang/MSVC. The multithreaded server stays a gcc
 * build by design: plain operations race (see runtime/orbit_api.h). */
#define __thread
#ifndef __ATOMIC_RELAXED
#define __ATOMIC_RELAXED 0
#define __ATOMIC_ACQUIRE 2
#define __ATOMIC_RELEASE 3
#define __ATOMIC_SEQ_CST 5
#endif
#define __atomic_load_n(ptr, memorder) (*(ptr))
#define __atomic_store_n(ptr, val, memorder) ((*(ptr)) = (val))
#define __atomic_fetch_add(ptr, val, memorder) (*(ptr) += (val), *(ptr) - (val))
#define __atomic_fetch_sub(ptr, val, memorder) (*(ptr) -= (val), *(ptr) + (val))
/* fetch_or/and return the NEW value, not the old one the gcc builtin returns;
 * no call site in this tree reads the result. */
#define __atomic_fetch_or(ptr, val, memorder) (*(ptr) |= (val))
#define __atomic_fetch_and(ptr, val, memorder) (*(ptr) &= (val))
#endif
#endif

#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include "performance.h"
#include "crt_compat.h"

#ifdef _WIN32
  #include <windows.h>
#else
  #include <time.h>
  #include <sys/time.h>
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit admission — Sovereign Computational Control Layer.
 *
 * Implements O(1) sharded admission control, thread-safe spinlocks,
 * monotonic timers, admission states (Stable, Shaped, Guarded, Siege)
 * and Computational Leases (budget limit for CPU, memory, SQL, HTTP).
 * ────────────────────────────────────────────────────────────────────── */

/* ── Types ──────────────────────────────────────────────────────────── */

typedef struct {
    int   pool_size;           /* admission pool: state thresholds are fractions of this */
    int   rate_limit;          /* tokens refilled per window_ms (sustained rps) */
    int   window_ms;           /* refill period; also the violation/decay period */
    int   burst;               /* bucket capacity in tokens; 0 = rate_limit */
    int   ban_threshold;       /* suspicion score to auto-ban */
    int   score_increment;     /* suspicion added per violation window */
    int   score_decay;         /* suspicion removed per clean window */
    int   ban_duration_s;      /* ban lifetime, seconds (<= 0 selects 300) */
    bool  enabled;
} OrbitAdmissionConfig;

typedef struct {
    uint8_t family; // 4 or 6
    union {
        uint32_t v4;
        uint8_t  v6[16];
    } addr;
} OrbitAdmissionIP;

/* admission 0.1: per-IP token bucket. tokens_milli is an integer milli-token
 * count so the hot path stays integer-only at -O0. last_violation_ns spaces
 * suspicion scoring to one unit per violation window: a single accidental
 * burst is ONE violation (429s, score += increment), never a ban trigger.
 * Sustained abuse across many windows is what reaches ban_threshold. */
typedef struct {
    OrbitAdmissionIP ip;
    uint64_t    last_refill_ns;
    uint64_t    last_violation_ns;
    uint64_t    last_score_decay_ns;
    int64_t     tokens_milli;
    int32_t     suspicion_score;
    bool        is_banned;
    uint64_t    banned_at_ns;
} OrbitAdmissionEntry;

typedef struct {
    volatile long locked;
} OrbitAdmissionLock;

#define ADMISSION_SLOTS_PER_SHARD 64
#define ADMISSION_SHARD_COUNT 1024

typedef struct {
    OrbitAdmissionEntry entries[ADMISSION_SLOTS_PER_SHARD];
    OrbitAdmissionLock  lock;
    uint32_t       count;
} OrbitAdmissionShard;

typedef enum {
    ADMISSION_STATE_STABLE,
    ADMISSION_STATE_SHAPED,
    ADMISSION_STATE_GUARDED,
    ADMISSION_STATE_SIEGE
} OrbitAdmissionState;

/* Trusted reverse proxies (env ORBIT_ADMISSION_TRUSTED_PROXIES at init, or
 * orbit_admission_add_trusted_proxy). Only a direct peer in this set may speak
 * for an X-Forwarded-For client; nobody else's XFF is ever believed. */
#define ADMISSION_MAX_TRUSTED_PROXIES 16
typedef struct { OrbitAdmissionIP net; int prefix; } AdmissionTrustedNet;

/* ── Monotonic Clock ────────────────────────────────────────────────── */

/** @brief Return the current monotonic time in nanoseconds. */
#ifdef ORBIT_ADMISSION_TEST
/* Deterministic clock for runtime/test_admission.c: the test TU defines the
 * global and steps it, so property tests are exact and fast. */
extern uint64_t orbit_admission_test_now_ns;
uint64_t orbit_admission_now_ns(void);
#else
uint64_t orbit_admission_now_ns(void);
#endif
void orbit_admission_add_trusted_proxy(const char* cidr);
bool orbit_admission_is_trusted_proxy(const char* ip_str);
bool orbit_admission_has_trusted_proxies(void);
void orbit_admission_effective_ip(const char* peer, const char* xff, char* out, size_t out_len);

/* ── Per-Route Rate Limits (admission 0.1 C3) ───────────────────────────── */

typedef struct {
    const char* method;
    const char* path;
    int rate;
    int window_ms;
    int burst;
} OrbitAdmissionRouteLimit;

#define ADMISSION_MAX_ROUTE_LIMITS 32
void orbit_admission_register_route_limit(const char* method, const char* path,
                                     int rate, int window_ms, int burst);

/* Per-route buckets: separate from global IP buckets so ban/score stay
 * global (route_id 0 path is the original orbit_admission_check) while rate
 * limiting is per (ip, route). Zero-false-ban preserved: route deny only
 * sets Retry-After, never scores unless the GLOBAL bucket also denied. */
typedef struct {
    OrbitAdmissionIP ip;
    int route_idx;
    uint64_t last_refill_ns;
    int64_t tokens_milli;
    bool used;
} AdmissionRouteBucket;

#define ADMISSION_ROUTE_SHARD_COUNT 16
#define ADMISSION_ROUTE_SLOTS_PER_SHARD 64
typedef struct {
    AdmissionRouteBucket slots[ADMISSION_ROUTE_SLOTS_PER_SHARD];
    OrbitAdmissionLock lock;
} AdmissionRouteShard;

bool orbit_admission_check(const char* ip_str);
bool orbit_admission_check_route(const char* ip_str, const char* method, const char* path);
void orbit_admission_init(OrbitAdmissionConfig config);
void orbit_admission_cleanup(void);
void orbit_admission_reset(void);
bool orbit_admission_check(const char* ip_str);
OrbitAdmissionLease* orbit_admission_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
void orbit_admission_lease_destroy(OrbitAdmissionLease* lease);
void orbit_admission_lease_abandon(void);
bool orbit_admission_lease_check_limits(size_t additional_response_bytes);
int orbit_sqlite_progress_handler(void* param);
uint64_t orbit_admission_get_total_checks(void);
uint64_t orbit_admission_get_total_blocked(void);
bool     orbit_admission_is_siege_mode(void);
int orbit_admission_get_suspicion(const char* ip_str);
int orbit_admission_last_retry_ms(void);
double orbit_admission_lease_joules(const OrbitAdmissionLease* lease);
uint64_t orbit_admission_lease_cycles(const OrbitAdmissionLease* lease);

#endif
