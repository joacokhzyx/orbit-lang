#ifndef ORBIT_KYNX_H
#define ORBIT_KYNX_H

#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Kynx — Compiled-in autonomous security layer.
 *
 * Kynx is not a middleware or a library. It is a property of every
 * compiled Orbit binary. It operates at the connection level before
 * any HTTP parsing or application logic executes.
 *
 * All thresholds are configurable at init time (driven by Atlas).
 * No hardcoded limits.
 * ────────────────────────────────────────────────────────────────────── */

/* ── Configuration ──────────────────────────────────────────────────── */

typedef struct {
    int   pool_size;           /* max tracked IPs */
    int   rate_limit;          /* requests per window */
    int   window_ms;           /* sliding window duration */
    int   ban_threshold;       /* suspicion score to auto-ban */
    int   score_increment;     /* suspicion added per violation */
    int   score_decay;         /* suspicion removed per clean window */
    bool  enabled;
} OrbitKynxConfig;

/* ── Per-client state ───────────────────────────────────────────────── */

typedef struct {
    char   ip[46];             /* IPv4 or IPv6 */
    long   last_request_ms;
    int    suspicion_score;
    int    request_count;
    bool   is_banned;
    long   banned_at_ms;       /* timestamp of ban for potential expiry */
} OrbitKynxEntry;

/* ── Global state ───────────────────────────────────────────────────── */

static OrbitKynxEntry*  orbit_kynx_pool   = NULL;
static OrbitKynxConfig  orbit_kynx_config = {0};
static uint64_t         orbit_kynx_total_checks   = 0;
static uint64_t         orbit_kynx_total_blocked   = 0;

/* ── Time ───────────────────────────────────────────────────────────── */

long orbit_kynx_now_ms(void) {
    return (long)(clock() * 1000 / CLOCKS_PER_SEC);
}

/* ── Init / Cleanup ─────────────────────────────────────────────────── */

void orbit_kynx_init(OrbitKynxConfig config) {
    orbit_kynx_config = config;
    orbit_kynx_pool   = (OrbitKynxEntry*)calloc((size_t)config.pool_size, sizeof(OrbitKynxEntry));
}

void orbit_kynx_cleanup(void) {
    free(orbit_kynx_pool);
    orbit_kynx_pool = NULL;
}

/* ── Core check ─────────────────────────────────────────────────────── */

bool orbit_kynx_check(const char* ip) {
    if (!orbit_kynx_config.enabled || !orbit_kynx_pool || !ip) return true;

    orbit_kynx_total_checks++;
    long now = orbit_kynx_now_ms();

    /* Find or allocate slot */
    int free_slot = -1;
    for (int i = 0; i < orbit_kynx_config.pool_size; i++) {
        if (orbit_kynx_pool[i].ip[0] == '\0') {
            if (free_slot < 0) free_slot = i;
            continue;
        }

        if (strncmp(orbit_kynx_pool[i].ip, ip, sizeof(orbit_kynx_pool[i].ip) - 1) != 0)
            continue;

        /* Found existing entry */
        OrbitKynxEntry* e = &orbit_kynx_pool[i];

        if (e->is_banned) {
            orbit_kynx_total_blocked++;
            orbit_perf_stats.kynx_blocks++; // Global telemetry
            return false;
        }

        long delta = now - e->last_request_ms;

        if (delta < orbit_kynx_config.window_ms) {
            e->request_count++;

            if (e->request_count > orbit_kynx_config.rate_limit) {
                e->suspicion_score += orbit_kynx_config.score_increment;

                if (e->suspicion_score >= orbit_kynx_config.ban_threshold) {
                    e->is_banned    = true;
                    e->banned_at_ms = now;
                    orbit_kynx_total_blocked++;
                    orbit_perf_stats.kynx_blocks++; // Global telemetry
                    return false;
                }
            }
        } else {
            /* New window — reset counter, decay suspicion */
            e->request_count = 1;
            if (e->suspicion_score > 0) {
                e->suspicion_score -= orbit_kynx_config.score_decay;
                if (e->suspicion_score < 0) e->suspicion_score = 0;
            }
        }

        e->last_request_ms = now;
        return true;
    }

    /* New IP — register in free slot */
    if (free_slot >= 0) {
        OrbitKynxEntry* e = &orbit_kynx_pool[free_slot];
        strncpy(e->ip, ip, sizeof(e->ip) - 1);
        e->ip[sizeof(e->ip) - 1] = '\0';
        e->last_request_ms  = now;
        e->request_count    = 1;
        e->suspicion_score  = 0;
        e->is_banned        = false;
        e->banned_at_ms     = 0;
    }

    /* No slot available — allow (fail open) */
    return true;
}

/* ── Reset ──────────────────────────────────────────────────────────── */

void orbit_kynx_reset(void) {
    if (orbit_kynx_pool) {
        memset(orbit_kynx_pool, 0, (size_t)orbit_kynx_config.pool_size * sizeof(OrbitKynxEntry));
    }
    orbit_kynx_total_checks  = 0;
    orbit_kynx_total_blocked = 0;
}

/* ── Stats ──────────────────────────────────────────────────────────── */

uint64_t orbit_kynx_get_total_checks(void)  { return orbit_kynx_total_checks; }
uint64_t orbit_kynx_get_total_blocked(void) { return orbit_kynx_total_blocked; }

#endif
