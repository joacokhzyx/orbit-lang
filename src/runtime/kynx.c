#ifndef ORBIT_KYNX_H
#define ORBIT_KYNX_H

#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include "performance.h"

#ifdef _WIN32
  #include <windows.h>
#else
  #include <time.h>
  #include <sys/time.h>
#endif

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Kynx — Sovereign Computational Control Layer.
 *
 * Implements O(1) sharded admission control, thread-safe spinlocks,
 * monotonic timers, admission states (Stable, Shaped, Guarded, Siege)
 * and Computational Leases (budget limit for CPU, memory, SQL, HTTP).
 * ────────────────────────────────────────────────────────────────────── */

/* ── Types ──────────────────────────────────────────────────────────── */

typedef struct {
    int   pool_size;           /* max tracked IPs */
    int   rate_limit;          /* requests per window */
    int   window_ms;           /* sliding window duration */
    int   ban_threshold;       /* suspicion score to auto-ban */
    int   score_increment;     /* suspicion added per violation */
    int   score_decay;         /* suspicion removed per clean window */
    bool  enabled;
} OrbitKynxConfig;

typedef struct {
    uint8_t family; // 4 or 6
    union {
        uint32_t v4;
        uint8_t  v6[16];
    } addr;
} OrbitKynxIP;

typedef struct {
    OrbitKynxIP ip;
    uint64_t    last_request_ns;
    int32_t     suspicion_score;
    int32_t     request_count;
    bool        is_banned;
    uint64_t    banned_at_ns;
} OrbitKynxEntry;

typedef struct {
    volatile long locked;
} OrbitKynxLock;

#define KYNX_SLOTS_PER_SHARD 16
#define KYNX_SHARD_COUNT 64

typedef struct {
    OrbitKynxEntry entries[KYNX_SLOTS_PER_SHARD];
    OrbitKynxLock  lock;
    uint32_t       count;
} OrbitKynxShard;

typedef enum {
    KYNX_STATE_STABLE,
    KYNX_STATE_SHAPED,
    KYNX_STATE_GUARDED,
    KYNX_STATE_SIEGE
} OrbitKynxState;

/* ── Global State ───────────────────────────────────────────────────── */

static OrbitKynxShard   orbit_kynx_shards[KYNX_SHARD_COUNT];
static OrbitKynxConfig  orbit_kynx_config = {0};
static volatile int64_t orbit_kynx_total_checks   = 0;
static volatile int64_t orbit_kynx_total_blocked  = 0;
static volatile int64_t orbit_kynx_active_leases  = 0;
static OrbitKynxState   orbit_kynx_state = KYNX_STATE_STABLE;

ORBIT_THREAD_LOCAL OrbitKynxLease* current_lease = NULL;

/* ── Spinlock Helper ────────────────────────────────────────────────── */

static inline void kynx_lock_acquire(OrbitKynxLock* lock) {
#ifdef _WIN32
    while (InterlockedExchange(&lock->locked, 1) == 1) {
        YieldProcessor();
    }
#else
    while (__sync_lock_test_and_set(&lock->locked, 1)) {
        #if defined(__x86_64__) || defined(__i386__)
        __builtin_ia32_pause();
        #endif
    }
#endif
}

static inline void kynx_lock_release(OrbitKynxLock* lock) {
#ifdef _WIN32
    InterlockedExchange(&lock->locked, 0);
#else
    __sync_lock_release(&lock->locked);
#endif
}

/* ── Monotonic Clock ────────────────────────────────────────────────── */

uint64_t orbit_kynx_now_ns(void) {
#ifdef _WIN32
    static LARGE_INTEGER frequency;
    static BOOL has_frequency = FALSE;
    if (!has_frequency) {
        QueryPerformanceFrequency(&frequency);
        has_frequency = TRUE;
    }
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (uint64_t)((counter.QuadPart * 1000000000ULL) / frequency.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

/* ── IP Parsing & Hashing ────────────────────────────────────────────── */

static bool kynx_parse_ip(const char* ip_str, OrbitKynxIP* out_ip) {
    if (!ip_str) return false;
    
    if (strchr(ip_str, ':') != NULL) {
        out_ip->family = 6;
        memset(out_ip->addr.v6, 0, 16);
        const char* p = ip_str;
        int i = 0;
        while (*p && i < 8) {
            if (*p == ':') {
                p++;
                if (*p == ':') {
                    p++;
                    break;
                }
                continue;
            }
            char* endptr;
            unsigned long val = strtoul(p, &endptr, 16);
            if (p == endptr) return false;
            out_ip->addr.v6[i * 2] = (uint8_t)(val >> 8);
            out_ip->addr.v6[i * 2 + 1] = (uint8_t)(val & 0xFF);
            i++;
            p = endptr;
        }
        return true;
    } else {
        out_ip->family = 4;
        int a, b, c, d;
        if (sscanf(ip_str, "%d.%d.%d.%d", &a, &b, &c, &d) == 4) {
            if (a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255) {
                out_ip->addr.v4 = ((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)c << 8) | (uint32_t)d;
                return true;
            }
        }
    }
    return false;
}

static uint32_t kynx_hash_ip(const OrbitKynxIP* ip) {
    uint32_t hash = 2166136261U;
    if (ip->family == 4) {
        hash ^= ip->addr.v4;
        hash *= 16777619U;
    } else {
        for (int i = 0; i < 16; i++) {
            hash ^= ip->addr.v6[i];
            hash *= 16777619U;
        }
    }
    return hash;
}

static bool kynx_ip_eq(const OrbitKynxIP* a, const OrbitKynxIP* b) {
    if (a->family != b->family) return false;
    if (a->family == 4) {
        return a->addr.v4 == b->addr.v4;
    } else {
        return memcmp(a->addr.v6, b->addr.v6, 16) == 0;
    }
}

/* ── Init / Cleanup ─────────────────────────────────────────────────── */

void orbit_kynx_init(OrbitKynxConfig config) {
    orbit_kynx_config = config;
    memset(orbit_kynx_shards, 0, sizeof(orbit_kynx_shards));
    orbit_kynx_total_checks = 0;
    orbit_kynx_total_blocked = 0;
    orbit_kynx_active_leases = 0;
    orbit_kynx_state = KYNX_STATE_STABLE;
}

void orbit_kynx_cleanup(void) {
    memset(orbit_kynx_shards, 0, sizeof(orbit_kynx_shards));
}

void orbit_kynx_reset(void) {
    memset(orbit_kynx_shards, 0, sizeof(orbit_kynx_shards));
    orbit_kynx_total_checks = 0;
    orbit_kynx_total_blocked = 0;
    orbit_kynx_active_leases = 0;
    orbit_kynx_state = KYNX_STATE_STABLE;
}

/* ── Admission Control Core ─────────────────────────────────────────── */

bool orbit_kynx_check(const char* ip_str) {
    if (!orbit_kynx_config.enabled || !ip_str) return true;

    OrbitKynxIP ip;
    if (!kynx_parse_ip(ip_str, &ip)) return true; // Fail open for malformed internally

    orbit_perf_atomic_inc64(&orbit_kynx_total_checks);
    uint32_t hash = kynx_hash_ip(&ip);
    uint32_t shard_idx = hash % KYNX_SHARD_COUNT;
    OrbitKynxShard* shard = &orbit_kynx_shards[shard_idx];

    uint64_t now = orbit_kynx_now_ns();
    uint64_t window_ns = (uint64_t)orbit_kynx_config.window_ms * 1000000ULL;

    kynx_lock_acquire(&shard->lock);

    int free_slot = -1;
    int oldest_slot = 0;
    uint64_t oldest_time = now;

    // Search within shard's fixed slots
    for (int i = 0; i < KYNX_SLOTS_PER_SHARD; i++) {
        OrbitKynxEntry* e = &shard->entries[i];
        if (e->ip.family == 0) {
            if (free_slot < 0) free_slot = i;
            continue;
        }

        if (kynx_ip_eq(&e->ip, &ip)) {
            // Found IP
            if (e->is_banned) {
                // Check if ban expired (e.g. 5 minutes)
                if (now - e->banned_at_ns > 300ULL * 1000000000ULL) {
                    e->is_banned = false;
                    e->suspicion_score /= 2;
                } else {
                    orbit_perf_atomic_inc64(&orbit_kynx_total_blocked);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_blocks);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_early_rejections);
                    kynx_lock_release(&shard->lock);
                    return false;
                }
            }

            uint64_t delta = now - e->last_request_ns;
            if (delta < window_ns) {
                e->request_count++;
                if (e->request_count > orbit_kynx_config.rate_limit) {
                    e->suspicion_score += orbit_kynx_config.score_increment;
                    if (e->suspicion_score >= orbit_kynx_config.ban_threshold) {
                        e->is_banned = true;
                        e->banned_at_ns = now;
                        orbit_perf_atomic_inc64(&orbit_kynx_total_blocked);
                        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_blocks);
                        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_early_rejections);
                        kynx_lock_release(&shard->lock);
                        return false;
                    }
                }
            } else {
                // Decay
                e->request_count = 1;
                if (e->suspicion_score > 0) {
                    e->suspicion_score -= orbit_kynx_config.score_decay;
                    if (e->suspicion_score < 0) e->suspicion_score = 0;
                }
            }
            e->last_request_ns = now;
            kynx_lock_release(&shard->lock);
            return true;
        }

        if (e->last_request_ns < oldest_time) {
            oldest_time = e->last_request_ns;
            oldest_slot = i;
        }
    }

    // Insert new IP
    int target_slot = free_slot;
    if (target_slot < 0) {
        // Table saturation - evict oldest entry
        target_slot = oldest_slot;
        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_table_saturations);
    }

    OrbitKynxEntry* e = &shard->entries[target_slot];
    e->ip = ip;
    e->last_request_ns = now;
    e->request_count = 1;
    e->suspicion_score = 0;
    e->is_banned = false;
    e->banned_at_ns = 0;

    if (free_slot >= 0) {
        shard->count++;
        orbit_perf_atomic_inc64((uint64_t*)&orbit_perf_stats.kynx_tracked_ips);
    }

    kynx_lock_release(&shard->lock);
    return true;
}

/* ── Admission Control States ───────────────────────────────────────── */

static inline void kynx_transition_state(OrbitKynxState new_state) {
    if (orbit_kynx_state != new_state) {
        orbit_kynx_state = new_state;
        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_state_transitions);
    }
}

static inline void kynx_update_admission_state(void) {
    int64_t active = orbit_kynx_active_leases;
    
    // Hysteresis based transitions
    if (orbit_kynx_state == KYNX_STATE_STABLE) {
        if (active > 32) kynx_transition_state(KYNX_STATE_SHAPED);
    } else if (orbit_kynx_state == KYNX_STATE_SHAPED) {
        if (active > 128) kynx_transition_state(KYNX_STATE_GUARDED);
        else if (active <= 24) kynx_transition_state(KYNX_STATE_STABLE);
    } else if (orbit_kynx_state == KYNX_STATE_GUARDED) {
        if (active > 512) kynx_transition_state(KYNX_STATE_SIEGE);
        else if (active <= 96) kynx_transition_state(KYNX_STATE_SHAPED);
    } else if (orbit_kynx_state == KYNX_STATE_SIEGE) {
        if (active <= 384) kynx_transition_state(KYNX_STATE_GUARDED);
    }
}

/* ── Computational Leases ───────────────────────────────────────────── */

OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena) {
    #ifdef _WIN32
    InterlockedIncrement64(&orbit_kynx_active_leases);
    #else
    __sync_fetch_and_add(&orbit_kynx_active_leases, 1);
    #endif
    kynx_update_admission_state();

    orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_admissions);

    OrbitKynxLease* lease = (OrbitKynxLease*)orbit_alloc(arena, sizeof(OrbitKynxLease));
    if (!lease) return NULL;
    memset(lease, 0, sizeof(OrbitKynxLease));

    // Default Route Budgets
    lease->deadline_ns = orbit_kynx_now_ns() + 500ULL * 1000000ULL; // 500ms
    lease->arena_limit = 16 * 1024 * 1024; // 16MB
    lease->request_limit = 64 * 1024; // 64KB
    lease->response_limit = 2 * 1024 * 1024; // 2MB
    lease->db_queries_limit = 10;
    lease->db_steps_limit = 100000;
    lease->flags = 0;

    // Apply strict rules based on current admission state
    if (orbit_kynx_state == KYNX_STATE_SHAPED) {
        // Reduce deadlines to 250ms, decrease DB step limit
        lease->deadline_ns = orbit_kynx_now_ns() + 250ULL * 1000000ULL;
        lease->db_steps_limit = 50000;
        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_throttled);
    } else if (orbit_kynx_state == KYNX_STATE_GUARDED) {
        // Severely restrict resources
        lease->deadline_ns = orbit_kynx_now_ns() + 100ULL * 1000000ULL; // 100ms
        lease->arena_limit = 2 * 1024 * 1024; // 2MB
        lease->db_queries_limit = 3;
        lease->db_steps_limit = 10000;
        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_throttled);
    } else if (orbit_kynx_state == KYNX_STATE_SIEGE) {
        // Check if critical route (health, auth, root)
        bool is_critical = false;
        if (path && (strcmp(path, "/health") == 0 || strcmp(path, "/auth") == 0 || strcmp(path, "/") == 0)) {
            is_critical = true;
        }
        
        if (!is_critical) {
            // Reject non-critical route immediately in Siege!
            lease->deadline_ns = 0; // immediate expiry
            lease->arena_limit = 0;
            lease->db_queries_limit = 0;
            lease->db_steps_limit = 0;
            lease->flags |= 1; // REJECTED flag
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_early_rejections);
        } else {
            // Critical route gets minimal budget
            lease->deadline_ns = orbit_kynx_now_ns() + 50ULL * 1000000ULL; // 50ms
            lease->arena_limit = 512 * 1024; // 512KB
            lease->db_queries_limit = 2;
            lease->db_steps_limit = 5000;
        }
    }

    // Apply custom routes config from Atlas (if matched)
    if (path) {
        if (strcmp(path, "/search") == 0) {
            lease->deadline_ns = orbit_kynx_now_ns() + 250ULL * 1000000ULL; // 250ms
            lease->arena_limit = 192 * 1024; // 192KB
            lease->response_limit = 1 * 1024 * 1024; // 1MB
            lease->db_queries_limit = 4;
            lease->db_steps_limit = 50000;
        }
    }

    current_lease = lease;
    return lease;
}

void orbit_kynx_lease_destroy(OrbitKynxLease* lease) {
    if (lease == current_lease) {
        current_lease = NULL;
    }
    #ifdef _WIN32
    InterlockedDecrement64(&orbit_kynx_active_leases);
    #else
    __sync_fetch_and_sub(&orbit_kynx_active_leases, 1);
    #endif
    kynx_update_admission_state();
}

bool orbit_kynx_lease_check_limits(size_t additional_response_bytes) {
    if (!current_lease) return true;

    // Check HTTP Response limit
    if (additional_response_bytes > 0) {
        if (current_lease->response_bytes + additional_response_bytes > current_lease->response_limit) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_response_budget_exhausted);
            return false;
        }
        current_lease->response_bytes += additional_response_bytes;
    }

    // Check Monotonic Deadline
    if (orbit_kynx_now_ns() > current_lease->deadline_ns) {
        orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_deadline_exhausted);
        return false;
    }

    return true;
}

/* ── SQLite Progress Handler Implementation ─────────────────────────── */

int orbit_sqlite_progress_handler(void* param) {
    (void)param;
    if (current_lease) {
        current_lease->db_steps++;
        if (current_lease->db_steps > current_lease->db_steps_limit) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_db_step_budget_exhausted);
            return 1; // Abort SQLite query execution!
        }
        if (orbit_kynx_now_ns() > current_lease->deadline_ns) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_deadline_exhausted);
            return 1; // Abort due to deadline!
        }
    }
    return 0;
}

/* ── Compatibility Getters ──────────────────────────────────────────── */

uint64_t orbit_kynx_get_total_checks(void)  { return (uint64_t)orbit_kynx_total_checks; }
uint64_t orbit_kynx_get_total_blocked(void) { return (uint64_t)orbit_kynx_total_blocked; }

#endif
