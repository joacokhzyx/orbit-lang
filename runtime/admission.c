#ifndef ORBIT_RT_ADMISSION_C
#define ORBIT_RT_ADMISSION_C

#include "module_prelude.h"
#include "admission.h"
#include "types.h"
#include "arena.h"
#include "energy.h"
#include "ledger.h"
#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#ifndef __ATOMIC_RELAXED
#endif
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

/* ── Global State ───────────────────────────────────────────────────── */

static OrbitAdmissionShard          orbit_admission_shards[ADMISSION_SHARD_COUNT];
static volatile uint64_t        orbit_admission_banned_bloom[1024] = {0};
static OrbitAdmissionConfig         orbit_admission_config = {0};
static volatile int64_t        orbit_admission_total_checks   = 0;
static volatile int64_t        orbit_admission_total_blocked  = 0;
static volatile int64_t        orbit_admission_active_leases  = 0;
static volatile OrbitAdmissionState orbit_admission_state = ADMISSION_STATE_STABLE;
static volatile bool           admission_siege_active = false;

/* Milliseconds until this thread's denied request may retry (Retry-After). */
static ORBIT_THREAD_LOCAL int admission_tls_retry_ms = 0;
static AdmissionTrustedNet admission_trusted[ADMISSION_MAX_TRUSTED_PROXIES];
static int admission_trusted_count = 0;

/* ── Spinlock Helper with Adaptive Backoff ──────────────────────────── */

static inline void admission_lock_acquire(OrbitAdmissionLock* lock) {
    int spins = 0;
#ifdef _WIN32
    while (InterlockedExchange(&lock->locked, 1) == 1) {
        if (++spins > 16) {
            YieldProcessor();
            spins = 0;
        }
    }
#else
    while (__sync_lock_test_and_set(&lock->locked, 1)) {
        if (++spins > 16) {
            #if defined(__x86_64__) || defined(__i386__)
            __builtin_ia32_pause();
            #endif
            spins = 0;
        }
    }
#endif
}

static inline void admission_lock_release(OrbitAdmissionLock* lock) {
#ifdef _WIN32
    InterlockedExchange(&lock->locked, 0);
#else
    __sync_lock_release(&lock->locked);
#endif
}
#ifdef ORBIT_ADMISSION_TEST
uint64_t orbit_admission_now_ns(void) {
    return orbit_admission_test_now_ns;
}
#else
uint64_t orbit_admission_now_ns(void) {
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
#endif

/* ── IP Parsing & Hashing ────────────────────────────────────────────── */

/// Fast 3-nanosecond IPv4 string parser (replaces slow sscanf)
static inline bool admission_fast_parse_ipv4(const char* str, uint32_t* out_v4) {
    uint32_t val = 0;
    uint32_t octet = 0;
    int dots = 0;

    for (const char* p = str; *p; p++) {
        char c = *p;
        if (c >= '0' && c <= '9') {
            octet = octet * 10 + (uint32_t)(c - '0');
            if (octet > 255) return false;
        } else if (c == '.') {
            if (dots >= 3) return false;
            val = (val << 8) | octet;
            octet = 0;
            dots++;
        } else {
            return false;
        }
    }
    if (dots != 3) return false;
    *out_v4 = (val << 8) | octet;
    return true;
}

/* Parse one "::"-free span of colon-separated hex groups (with an optional
 * trailing dotted-quad) into bytes. Returns bytes written or -1. */
static int admission_parse_v6_span(const char* s, const char* end, uint8_t* dst) {
    int written = 0;
    const char* p = s;
    while (p < end) {
        const char* colon = (const char*)memchr(p, ':', (size_t)(end - p));
        if (!colon) colon = end;
        if (memchr(p, '.', (size_t)(colon - p)) != NULL) {
            /* dotted-quad tail: only legal as the final element */
            char tmp[16];
            size_t n = (size_t)(end - p);
            if (n == 0 || n >= sizeof(tmp) || colon != end) return -1;
            memcpy(tmp, p, n);
            tmp[n] = '\0';
            uint32_t v4 = 0;
            if (!admission_fast_parse_ipv4(tmp, &v4)) return -1;
            if (written + 4 > 16) return -1;
            dst[written++] = (uint8_t)(v4 >> 24);
            dst[written++] = (uint8_t)(v4 >> 16);
            dst[written++] = (uint8_t)(v4 >> 8);
            dst[written++] = (uint8_t)v4;
            p = end;
            break;
        }
        if (colon == p) return -1; /* empty group (stray "::" inside span) */
        unsigned long val = 0;
        for (const char* q = p; q < colon; q++) {
            char c = *q;
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else return -1;
            val = (val << 4) | (unsigned long)d;
            if (val > 0xFFFFul) return -1;
        }
        if (written + 2 > 16) return -1;
        dst[written++] = (uint8_t)(val >> 8);
        dst[written++] = (uint8_t)(val & 0xFF);
        p = colon;
        if (p == end) break;
        p++; /* skip the single separator colon */
        if (p == end) return -1; /* trailing single colon */
    }
    return written;
}

/* Full IPv6 text form: head "::" tail. The zero run sits between the two
 * spans, so "::1", "2001:db8::1" and the full 8-group form all compare
 * equal. Rejects embedded "::" in the tail, zones ("%"), and junk. */
static bool admission_parse_ipv6(const char* str, uint8_t out[16]) {
    memset(out, 0, 16);
    if (!str || !*str) return false;
    const char* sep = strstr(str, "::");
    if (!sep) {
        return admission_parse_v6_span(str, str + strlen(str), out) == 16;
    }
    int hb = admission_parse_v6_span(str, sep, out);
    if (hb < 0 || hb > 14) return false;
    const char* tail = sep + 2;
    if (strstr(tail, "::") != NULL) return false; /* only one zero run */
    int tb = 0;
    if (*tail != '\0') {
        uint8_t tailb[16] = {0};
        tb = admission_parse_v6_span(tail, tail + strlen(tail), tailb);
        if (tb < 0 || hb + tb > 16) return false;
        memcpy(out + 16 - tb, tailb, (size_t)tb);
    }
    return true;
}

static bool admission_parse_ip(const char* ip_str, OrbitAdmissionIP* out_ip) {
    if (!ip_str) return false;

    if (strchr(ip_str, ':') != NULL) {
        out_ip->family = 6;
        return admission_parse_ipv6(ip_str, out_ip->addr.v6);
    } else {
        out_ip->family = 4;
        return admission_fast_parse_ipv4(ip_str, &out_ip->addr.v4);
    }
}

static uint32_t admission_hash_ip(const OrbitAdmissionIP* ip) {
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

static bool admission_ip_eq(const OrbitAdmissionIP* a, const OrbitAdmissionIP* b) {
    if (a->family != b->family) return false;
    if (a->family == 4) {
        return a->addr.v4 == b->addr.v4;
    } else {
        return memcmp(a->addr.v6, b->addr.v6, 16) == 0;
    }
}

/* ── Trusted Proxies / X-Forwarded-For ─────────────────────────────── */

/** Register a trusted reverse proxy: "1.2.3.4", "10.0.0.0/8", "2001:db8::/32". */
void orbit_admission_add_trusted_proxy(const char* cidr) {
    if (!cidr || !*cidr) return;
    char buf[64];
    size_t n = strlen(cidr);
    if (n == 0 || n >= sizeof(buf)) return;
    memcpy(buf, cidr, n + 1);
    int prefix = -1;
    char* slash = strchr(buf, '/');
    if (slash) {
        *slash = '\0';
        /* Digits only, one to three of them. atoi read "abc" and "" as 0,
         * and a /0 entry trusts every address as a proxy, which lets any
         * client write its own X-Forwarded-For. A malformed prefix trusts
         * nothing. */
        const char* digits = slash + 1;
        size_t nd = strlen(digits);
        if (nd == 0 || nd > 3) return;
        prefix = 0;
        for (size_t i = 0; i < nd; i++) {
            if (digits[i] < '0' || digits[i] > '9') return;
            prefix = prefix * 10 + (digits[i] - '0');
        }
    }
    OrbitAdmissionIP net;
    if (!admission_parse_ip(buf, &net)) return;
    int max = (net.family == 4) ? 32 : 128;
    if (prefix < 0) prefix = max;
    if (prefix > max) return;
    if (admission_trusted_count >= ADMISSION_MAX_TRUSTED_PROXIES) return;
    for (int i = 0; i < admission_trusted_count; i++) {
        if (admission_ip_eq(&admission_trusted[i].net, &net) && admission_trusted[i].prefix == prefix) return;
    }
    admission_trusted[admission_trusted_count].net = net;
    admission_trusted[admission_trusted_count].prefix = prefix;
    admission_trusted_count++;
}

static bool admission_ip_in_net(const OrbitAdmissionIP* ip, const AdmissionTrustedNet* net) {
    if (ip->family != net->net.family) return false;
    int total = (ip->family == 4) ? 32 : 128;
    int prefix = net->prefix;
    if (prefix < 0) prefix = 0;
    if (prefix > total) prefix = total;
    uint8_t a[16], b[16];
    memset(a, 0, sizeof(a));
    memset(b, 0, sizeof(b));
    if (ip->family == 4) {
        a[0] = (uint8_t)(ip->addr.v4 >> 24); a[1] = (uint8_t)(ip->addr.v4 >> 16);
        a[2] = (uint8_t)(ip->addr.v4 >> 8);  a[3] = (uint8_t)ip->addr.v4;
        b[0] = (uint8_t)(net->net.addr.v4 >> 24); b[1] = (uint8_t)(net->net.addr.v4 >> 16);
        b[2] = (uint8_t)(net->net.addr.v4 >> 8);  b[3] = (uint8_t)net->net.addr.v4;
    } else {
        memcpy(a, ip->addr.v6, 16);
        memcpy(b, net->net.addr.v6, 16);
    }
    int full = prefix / 8, rem = prefix % 8;
    if (full > 0 && memcmp(a, b, (size_t)full) != 0) return false;
    if (rem) {
        uint8_t mask = (uint8_t)(0xFFu << (8 - rem));
        if ((a[full] & mask) != (b[full] & mask)) return false;
    }
    return true;
}

bool orbit_admission_is_trusted_proxy(const char* ip_str) {
    if (!ip_str || admission_trusted_count == 0) return false;
    OrbitAdmissionIP ip;
    if (!admission_parse_ip(ip_str, &ip)) return false;
    for (int i = 0; i < admission_trusted_count; i++) {
        if (admission_ip_in_net(&ip, &admission_trusted[i])) return true;
    }
    return false;
}

/** @brief Whether any trusted reverse proxy is configured. With none, no
 * X-Forwarded-For value can ever be believed, so callers skip reading it. */
bool orbit_admission_has_trusted_proxies(void) {
    return admission_trusted_count > 0;
}

/** Resolve the effective client IP: XFF is believed ONLY when the direct
 * peer is a registered trusted proxy; walk the comma list right-to-left and
 * take the first non-trusted hop. Untrusted peers keep their own address. */
void orbit_admission_effective_ip(const char* peer, const char* xff, char* out, size_t out_len) {
    if (!out || out_len == 0) return;
    out[0] = '\0';
    if (!peer) return;
    size_t pn = strlen(peer);
    if (pn >= out_len) pn = out_len - 1;
    memcpy(out, peer, pn);
    out[pn] = '\0';
    if (!xff || !*xff || !orbit_admission_is_trusted_proxy(peer)) return;

    const char* p = xff + strlen(xff);
    while (p > xff) {
        const char* seg_end = p;
        const char* seg_start = p;
        while (seg_start > xff && *(seg_start - 1) != ',') seg_start--;
        while (seg_start < seg_end && (*seg_start == ' ' || *seg_start == '\t')) seg_start++;
        const char* e2 = seg_end;
        while (e2 > seg_start && (e2[-1] == ' ' || e2[-1] == '\t')) e2--;
        if (e2 > seg_start) {
            char cand[64];
            size_t cn = (size_t)(e2 - seg_start);
            if (cn >= sizeof(cand)) cn = sizeof(cand) - 1;
            memcpy(cand, seg_start, cn);
            cand[cn] = '\0';
            OrbitAdmissionIP cip;
            if (admission_parse_ip(cand, &cip) && !orbit_admission_is_trusted_proxy(cand)) {
                size_t wn = strlen(cand);
                if (wn >= out_len) wn = out_len - 1;
                memcpy(out, cand, wn);
                out[wn] = '\0';
                return;
            }
        }
        if (seg_start <= xff) break;
        p = seg_start - 1; /* step over the comma */
    }
    /* every hop trusted (or unparseable): keep the peer address */
}
static OrbitAdmissionRouteLimit admission_route_limits[ADMISSION_MAX_ROUTE_LIMITS];
static int admission_route_limit_count = 0;

void orbit_admission_register_route_limit(const char* method, const char* path,
                                     int rate, int window_ms, int burst) {
    if (!method || !path || rate <= 0) return;
    if (admission_route_limit_count >= ADMISSION_MAX_ROUTE_LIMITS) {
        /* Table overflow is observable (see docs/ADMISSION.md); duplicates below
         * stay silent because re-registering is idempotent. */
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_route_limit_drops);
        return;
    }
    for (int i = 0; i < admission_route_limit_count; i++) {
        if (strcmp(admission_route_limits[i].method, method) == 0 &&
            strcmp(admission_route_limits[i].path, path) == 0) {
            return; /* already registered */
        }
    }
    OrbitAdmissionRouteLimit* r = &admission_route_limits[admission_route_limit_count++];
    r->method = method;
    r->path = path;
    r->rate = rate;
    r->window_ms = (window_ms > 0) ? window_ms : 1000;
    r->burst = (burst > 0) ? burst : rate;
}

/* Simple pattern match: ':' segment, '{...}' segment, or trailing '*' */
static bool admission_path_match(const char* pattern, const char* path) {
    if (!pattern || !path) return false;
    if (strcmp(pattern, path) == 0) return true;
    /* One trailing slash is ignored on either side, which is what the router
     * does (http.c:785-786). Without it a request for `/ingest/` missed the
     * limit declared on `/ingest` and fell to the global gate. */
    size_t pl = strlen(pattern);
    size_t sl = strlen(path);
    if (pl > 1 && pattern[pl - 1] == '/') pl--;
    if (sl > 1 && path[sl - 1] == '/') sl--;
    if (pl == sl && pl > 0 && strncmp(pattern, path, pl) == 0) return true;
    const char* p = pattern;
    const char* s = path;
    while (*p && *s) {
        if (p[0] == '*' && p[1] == '\0') return true;
        if (p[0] == ':' || p[0] == '{') {
            const char* seg = p;
            while (*p && *p != '/') p++;
            /* `:name...` captures the remaining segments, which is what the
             * router's multi-parameter pass does. Treated as one segment, the
             * pattern matched only a single-segment path, so a multi-segment
             * request fell through to the global gate and the declared limit
             * never applied. */
            if (p - seg >= 3 && p[-1] == '.' && p[-2] == '.' && p[-3] == '.') return true;
            while (*s && *s != '/') s++;
            continue;
        }
        if (*p != *s) return false;
        p++; s++;
    }
    if (*p == '*' && p[1] == '\0') return true;
    return *p == '\0' && *s == '\0';
}

/* Route buckets striped over per-shard locks: same 1024-slot capacity as a
 * flat table (16 shards x 64 slots), but one hot (IP, route) pair no longer
 * serializes every other route behind a single global lock. The shard mixes
 * the IP hash with the route index so distinct routes spread evenly. */
static AdmissionRouteShard admission_route_shards[ADMISSION_ROUTE_SHARD_COUNT];

static unsigned admission_route_shard(const OrbitAdmissionIP* ip, int route_idx) {
    return (admission_hash_ip(ip) ^ (uint32_t)((uint32_t)route_idx * 0x9E3779B1u))
        % ADMISSION_ROUTE_SHARD_COUNT;
}

static void admission_route_refill(AdmissionRouteBucket* b, int rate, int window_ms, int burst, uint64_t now) {
    if (b->last_refill_ns == 0 || now <= b->last_refill_ns) {
        b->last_refill_ns = now;
        return;
    }
    uint64_t elapsed = now - b->last_refill_ns;
    uint64_t max_el = (uint64_t)window_ms * 1000000ULL * 10ULL;
    if (elapsed > max_el) elapsed = max_el;
    b->last_refill_ns = now;
    int64_t gained = (int64_t)((elapsed * (uint64_t)rate * 1000ULL) /
                               ((uint64_t)window_ms * 1000000ULL));
    b->tokens_milli += gained;
    /* Capacity is what the route declared as burst. Capping at the refill
     * rate discarded the declaration on the first refill, so a route with
     * rate=2/s burst=10 answered with 2 after any idle time. */
    int64_t cap = (int64_t)(burst > 0 ? burst : (rate > 0 ? rate : 1)) * 1000;
    if (b->tokens_milli > cap) b->tokens_milli = cap;
}

static int admission_route_retry_ms(const AdmissionRouteBucket* b, int rate, int window_ms) {
    int64_t need = 1000 - b->tokens_milli;
    if (need <= 0) return 1;
    if (rate < 1) rate = 1;
    if (window_ms < 1) window_ms = 1;
    int64_t ms = (need * (int64_t)window_ms) / ((int64_t)rate * 1000);
    if (ms < 1) ms = 1;
    if (ms > window_ms) ms = window_ms;
    return (int)ms;
}
 /* defined below; the route gate falls back to it */
bool orbit_admission_check_route(const char* ip_str, const char* method, const char* path) {
    admission_tls_retry_ms = 0;
    if (!__atomic_load_n(&orbit_admission_config.enabled, __ATOMIC_RELAXED) || !ip_str)
        return true;
    if (!method || !path) return orbit_admission_check(ip_str);

    /* Find matching route limit (linear; few annotated routes). Static wins
     * over parametric, which is the order the router uses: c_backend.orb runs
     * every exact path comparison before the pattern passes. A single
     * first-match scan made the limit depend on declaration order, so a
     * parametric route declared first charged its bucket to a static path the
     * router served from a different handler. */
    int route_idx = -1;
    const OrbitAdmissionRouteLimit* lim = NULL;
    for (int i = 0; i < admission_route_limit_count; i++) {
        if (strcmp(admission_route_limits[i].method, method) != 0) continue;
        if (strcmp(admission_route_limits[i].path, path) == 0) {
            route_idx = i;
            lim = &admission_route_limits[i];
            break;
        }
    }
    for (int i = 0; lim == NULL && i < admission_route_limit_count; i++) {
        if (strcmp(admission_route_limits[i].method, method) != 0) continue;
        if (admission_path_match(admission_route_limits[i].path, path)) {
            route_idx = i;
            lim = &admission_route_limits[i];
            break;
        }
    }
    if (!lim) return orbit_admission_check(ip_str); /* unannotated → global only */

    OrbitAdmissionIP ip;
    if (!admission_parse_ip(ip_str, &ip)) return true;

    uint64_t now = orbit_admission_now_ns();
    int rate = lim->rate;
    int win = lim->window_ms;
    int burst = lim->burst;
    if (rate < 1) rate = 1;
    if (win < 1) win = 1;
    if (burst < 1) burst = rate;

    /* Find/create route bucket for (ip, route_idx) within its shard. */
    AdmissionRouteShard* rshard = &admission_route_shards[admission_route_shard(&ip, route_idx)];
    admission_lock_acquire(&rshard->lock);
    AdmissionRouteBucket* b = NULL;
    int free_slot = -1;
    int oldest_slot = 0;
    uint64_t oldest_time = now;
    for (int i = 0; i < ADMISSION_ROUTE_SLOTS_PER_SHARD; i++) {
        AdmissionRouteBucket* c = &rshard->slots[i];
        if (!c->used) {
            if (free_slot < 0) free_slot = i;
            continue;
        }
        if (c->route_idx == route_idx && admission_ip_eq(&c->ip, &ip)) {
            b = c;
            break;
        }
        if (c->last_refill_ns < oldest_time) {
            oldest_time = c->last_refill_ns;
            oldest_slot = i;
        }
    }
    if (!b) {
        int slot = free_slot >= 0 ? free_slot : oldest_slot;
        b = &rshard->slots[slot];
        memset(b, 0, sizeof(*b));
        b->ip = ip;
        b->route_idx = route_idx;
        b->used = true;
        b->last_refill_ns = now;
        b->tokens_milli = (int64_t)burst * 1000 - 1000; /* spend insert */
        if (b->tokens_milli < 0) b->tokens_milli = 0;
        admission_lock_release(&rshard->lock);
        return orbit_admission_check(ip_str); /* still run global gate */
    }

    admission_route_refill(b, rate, win, burst, now);
    if (b->tokens_milli >= 1000) {
        b->tokens_milli -= 1000;
        admission_lock_release(&rshard->lock);
        return orbit_admission_check(ip_str);
    }
    admission_tls_retry_ms = admission_route_retry_ms(b, rate, win);
    __atomic_fetch_add(&orbit_admission_total_blocked, 1, __ATOMIC_RELAXED);
    orbit_perf_atomic_inc64(&orbit_perf_stats.admission_blocks);
    admission_lock_release(&rshard->lock);
    return false; /* route rate deny: Retry-After only, NO score/ban */
}

/* ── Init / Cleanup ─────────────────────────────────────────────────── */

/** @brief Next comma-separated token in a mutable buffer, or NULL at the end.
 *
 *  Hand-rolled rather than strtok: MSVC deprecates strtok in favour of
 *  strtok_s, whose signature needs a context pointer threaded through every
 *  call, and this walks a single local buffer. Empty fields are returned as
 *  empty tokens instead of being collapsed, which is what the caller below
 *  already handles by skipping tokens whose first byte is NUL. */
static char* admission_next_csv_token(char** cursor) {
    char* s = *cursor;
    if (!s || *s == '\0') return NULL;
    char* comma = strchr(s, ',');
    if (comma) {
        *comma = '\0';
        *cursor = comma + 1;
    } else {
        *cursor = s + strlen(s);
    }
    return s;
}

/** @brief Initialise admission with @p config, zeroing all shard tables and counters. */
void orbit_admission_init(OrbitAdmissionConfig config) {
    orbit_admission_config = config;
    __atomic_store_n(&orbit_admission_config.enabled, config.enabled, __ATOMIC_SEQ_CST);
    memset(orbit_admission_shards, 0, sizeof(orbit_admission_shards));
    __atomic_store_n(&orbit_admission_total_checks, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_total_blocked, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_active_leases, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_state, ADMISSION_STATE_STABLE, __ATOMIC_SEQ_CST);
    __atomic_store_n(&admission_siege_active, false, __ATOMIC_SEQ_CST);
    /* Trusted proxies are deployment config: reload from env every init so
     * reset() + init() sequences (tests) never inherit stale entries. */
    admission_trusted_count = 0;
    {
        const char* env = orbit_env_get("ORBIT_ADMISSION_TRUSTED_PROXIES");
        if (env && *env) {
            char list[512];
            size_t en = strlen(env);
            if (en >= sizeof(list)) en = sizeof(list) - 1;
            memcpy(list, env, en);
            list[en] = '\0';
            char* cursor = list;
            char* tok = admission_next_csv_token(&cursor);
            while (tok) {
                while (*tok == ' ' || *tok == '\t') tok++;
                char* tail = tok + strlen(tok);
                while (tail > tok && (tail[-1] == ' ' || tail[-1] == '\t')) {
                    tail--;
                    *tail = '\0';
                }
                if (*tok) orbit_admission_add_trusted_proxy(tok);
                tok = admission_next_csv_token(&cursor);
            }
        }
    }
}

/** @brief Wipe all shard tables (e.g., when the server is stopping). */
void orbit_admission_cleanup(void) {
    memset(orbit_admission_shards, 0, sizeof(orbit_admission_shards));
    memset(admission_route_shards, 0, sizeof(admission_route_shards));
}

/** @brief Reset all shard tables and global counters to their initial state. */
void orbit_admission_reset(void) {
    memset(orbit_admission_shards, 0, sizeof(orbit_admission_shards));
    memset(admission_route_shards, 0, sizeof(admission_route_shards));
    admission_route_limit_count = 0;
    __atomic_store_n(&orbit_admission_total_checks, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_total_blocked, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_active_leases, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&orbit_admission_state, ADMISSION_STATE_STABLE, __ATOMIC_SEQ_CST);
    __atomic_store_n(&admission_siege_active, false, __ATOMIC_SEQ_CST);
    admission_trusted_count = 0;
}

/* ── Admission Control Core ─────────────────────────────────────────── */

/* ── Token Bucket Internals ──────────────────────────────────────────── */

static int admission_effective_burst(void) {
    int b = orbit_admission_config.burst;
    if (b <= 0) b = orbit_admission_config.rate_limit;
    if (b < 1) b = 1;
    return b;
}

/* Ban lifetime in nanoseconds; a non-positive config selects the 300 s
 * default so generated servers (which leave the field zero) keep it. */
static uint64_t admission_ban_duration_ns(void) {
    int s = orbit_admission_config.ban_duration_s;
    if (s <= 0) s = 300;
    return (uint64_t)s * 1000000000ULL;
}

/* Refill the bucket for elapsed time up to @p now, clamped to capacity. */
static void admission_refill(OrbitAdmissionEntry* e, uint64_t now) {
    int rate = orbit_admission_config.rate_limit;
    int win = orbit_admission_config.window_ms;
    if (rate < 1) rate = 1;
    if (win < 1) win = 1;
    int64_t cap_milli = (int64_t)admission_effective_burst() * 1000;
    if (e->last_refill_ns == 0 || now <= e->last_refill_ns) {
        e->last_refill_ns = now;
        return;
    }
    uint64_t elapsed = now - e->last_refill_ns;
    /* Idle time beyond ~10 windows already fills the bucket; capping keeps
     * the multiply bounded (no overflow on multi-day idles). */
    uint64_t max_el = (uint64_t)win * 1000000ULL * 10ULL;
    if (elapsed > max_el) elapsed = max_el;
    e->last_refill_ns = now;
    /* milli-tokens = elapsed_ns * rate * 1000 / window_ns */
    int64_t gained = (int64_t)((elapsed * (uint64_t)rate * 1000ULL) /
                               ((uint64_t)win * 1000000ULL));
    e->tokens_milli += gained;
    if (e->tokens_milli > cap_milli) e->tokens_milli = cap_milli;
}

/* ms until the bucket holds one full token (what Retry-After should say). */
static int admission_retry_after_ms(const OrbitAdmissionEntry* e) {
    int64_t need = 1000 - e->tokens_milli;
    if (need <= 0) return 1;
    int rate = orbit_admission_config.rate_limit;
    int win = orbit_admission_config.window_ms;
    if (rate < 1) rate = 1;
    if (win < 1) win = 1;
    int64_t ms = (need * (int64_t)win) / ((int64_t)rate * 1000);
    if (ms < 1) ms = 1;
    if (ms > win) ms = win;
    return (int)ms;
}

/** @brief Check whether the client at @p ip_str is allowed to proceed.  Returns true (allow) or false (block/ban). */
/* admission 0.1: multi-hash Bloom maintenance (k=4, double-derived indexes).
 * The filter is a NEGATIVE CACHE over the ban set, never the authority. */
static void admission_bloom_apply(uint32_t hash, int set) {
    for (int j = 0; j < 4; j++) {
        uint32_t idx = (hash + (uint32_t)(j * 0x9E3779B9u)) % 1024u;
        uint64_t bit = 1ULL << ((hash + 61u * (uint32_t)j) & 63u);
        if (set) {
            __atomic_fetch_or(&orbit_admission_banned_bloom[idx], bit, __ATOMIC_SEQ_CST);
        } else {
            __atomic_fetch_and(&orbit_admission_banned_bloom[idx], ~bit, __ATOMIC_SEQ_CST);
        }
    }
}

bool orbit_admission_check(const char* ip_str) {
    admission_tls_retry_ms = 0;
    if (!__atomic_load_n(&orbit_admission_config.enabled, __ATOMIC_RELAXED) || !ip_str) return true;

    OrbitAdmissionIP ip;
    if (!admission_parse_ip(ip_str, &ip)) return true; // Fail open for malformed internally

    __atomic_fetch_add(&orbit_admission_total_checks, 1, __ATOMIC_RELAXED);
    uint32_t hash = admission_hash_ip(&ip);

    /* NOTE: a bloom pre-check used to live here, but its result was never
     * consumed: every request must still be counted in the shard table
     * below (otherwise new IPs could never reach the ban threshold), so a
     * negative-cache fast path would skip mandatory bookkeeping. The
     * authoritative table lookup is the single decision point. */
    uint32_t shard_idx = hash % ADMISSION_SHARD_COUNT;
    OrbitAdmissionShard* shard = &orbit_admission_shards[shard_idx];

    uint64_t now = orbit_admission_now_ns();
    uint64_t window_ns = (uint64_t)orbit_admission_config.window_ms * 1000000ULL;

    admission_lock_acquire(&shard->lock);

    int free_slot = -1;
    int oldest_slot = 0;
    uint64_t oldest_time = now;

    // Search within shard's fixed slots
    for (int i = 0; i < ADMISSION_SLOTS_PER_SHARD; i++) {
        OrbitAdmissionEntry* e = &shard->entries[i];
        if (e->ip.family == 0) {
            if (free_slot < 0) free_slot = i;
            continue;
        }

        if (admission_ip_eq(&e->ip, &ip)) {
            // Found IP
            if (e->is_banned) {
                // Check if ban expired (ban_duration_s, default 5 minutes)
                if (now - e->banned_at_ns > admission_ban_duration_ns()) {
                    e->is_banned = false;
                    e->suspicion_score /= 2;
                    admission_bloom_apply(hash, 0);
                } else {
                    uint64_t left = admission_ban_duration_ns() - (now - e->banned_at_ns);
                    admission_tls_retry_ms = (int)(left / 1000000ULL);
                    __atomic_fetch_add(&orbit_admission_total_blocked, 1, __ATOMIC_RELAXED);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.admission_blocks);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.admission_early_rejections);
                    admission_lock_release(&shard->lock);
                    return false;
                }
            }

            admission_refill(e, now);

            if (e->tokens_milli >= 1000) {
                /* Clean admission: spend a token, decay suspicion at most
                 * once per window so a legit client walks its score down. */
                e->tokens_milli -= 1000;
                if (e->suspicion_score > 0 &&
                    now - e->last_score_decay_ns >= window_ns) {
                    e->suspicion_score -= orbit_admission_config.score_decay;
                    if (e->suspicion_score < 0) e->suspicion_score = 0;
                    e->last_score_decay_ns = now;
                }
                admission_lock_release(&shard->lock);
                return true;
            }

            /* Bucket empty: deny with Retry-After. Score at most one unit
             * per violation window — sustained abuse is what bans, a single
             * burst is not. */
            admission_tls_retry_ms = admission_retry_after_ms(e);
            if (now - e->last_violation_ns >= window_ns) {
                e->suspicion_score += orbit_admission_config.score_increment;
                e->last_violation_ns = now;
                if (e->suspicion_score >= orbit_admission_config.ban_threshold) {
                    e->is_banned = true;
                    e->banned_at_ns = now;
                    admission_bloom_apply(hash, 1);
                    __atomic_fetch_add(&orbit_admission_total_blocked, 1, __ATOMIC_RELAXED);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.admission_blocks);
                    orbit_perf_atomic_inc64(&orbit_perf_stats.admission_early_rejections);
                    admission_lock_release(&shard->lock);
                    return false;
                }
            }
            __atomic_fetch_add(&orbit_admission_total_blocked, 1, __ATOMIC_RELAXED);
            orbit_perf_atomic_inc64(&orbit_perf_stats.admission_blocks);
            admission_lock_release(&shard->lock);
            return false;
        }

        if (e->last_refill_ns < oldest_time) {
            oldest_time = e->last_refill_ns;
            oldest_slot = i;
        }
    }

    // Insert new IP: bucket starts full (first-timers get the burst).
    int target_slot = free_slot;
    if (target_slot < 0) {
        // Table saturation - evict oldest entry
        target_slot = oldest_slot;
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_table_saturations);
    }

    OrbitAdmissionEntry* e = &shard->entries[target_slot];
    e->ip = ip;
    e->last_refill_ns = now;
    e->last_violation_ns = 0;
    e->last_score_decay_ns = now;
    /* Bucket starts full but this very request spends one token: the
     * admitting check costs a token for new IPs too (burst exactly burst). */
    e->tokens_milli = (int64_t)admission_effective_burst() * 1000 - 1000;
    e->suspicion_score = 0;
    e->is_banned = false;
    e->banned_at_ns = 0;

    if (free_slot >= 0) {
        shard->count++;
        orbit_perf_atomic_inc32(&orbit_perf_stats.admission_tracked_ips);
    }

    admission_lock_release(&shard->lock);
    return true;
}

/* ── Admission Control States ───────────────────────────────────────── */

static inline void admission_transition_state(OrbitAdmissionState new_state) {
    OrbitAdmissionState cur = (OrbitAdmissionState)__atomic_load_n(&orbit_admission_state, __ATOMIC_RELAXED);
    if (cur != new_state) {
        __atomic_store_n(&orbit_admission_state, new_state, __ATOMIC_SEQ_CST);
        bool siege = (new_state == ADMISSION_STATE_SIEGE);
        __atomic_store_n(&admission_siege_active, siege, __ATOMIC_SEQ_CST);
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_state_transitions);
    }
}

/* Admission thresholds as fractions of the configured pool_size, with
 * 75% hysteresis on release. pool_size <= 0 keeps the historical absolute
 * scale (512); tiny pools clamp to the 16-scale so tiers stay ordered.
 * pool=512 reproduces the legacy 32/128/512 - 24/96/384 exactly. */
static inline void admission_pool_thresholds(int* shaped, int* guarded, int* siege) {
    int pool = orbit_admission_config.pool_size;
    if (pool <= 0) pool = 512;
    if (pool < 16) pool = 16;
    *shaped = pool / 16;
    *guarded = pool / 4;
    *siege = pool;
    if (*shaped < 1) *shaped = 1;
    if (*guarded <= *shaped) *guarded = *shaped + 1;
    if (*siege <= *guarded) *siege = *guarded + 1;
}

static inline void update_admission_state(void) {
    int64_t active = __atomic_load_n(&orbit_admission_active_leases, __ATOMIC_RELAXED);
    OrbitAdmissionState state = (OrbitAdmissionState)__atomic_load_n(&orbit_admission_state, __ATOMIC_RELAXED);
    int shaped, guarded, siege;
    admission_pool_thresholds(&shaped, &guarded, &siege);

    // Hysteresis based transitions (release at 3/4 of each entry level)
    if (state == ADMISSION_STATE_STABLE) {
        if (active > shaped) admission_transition_state(ADMISSION_STATE_SHAPED);
    } else if (state == ADMISSION_STATE_SHAPED) {
        if (active > guarded) admission_transition_state(ADMISSION_STATE_GUARDED);
        else if (active <= (shaped * 3) / 4) admission_transition_state(ADMISSION_STATE_STABLE);
    } else if (state == ADMISSION_STATE_GUARDED) {
        if (active > siege) admission_transition_state(ADMISSION_STATE_SIEGE);
        else if (active <= (guarded * 3) / 4) admission_transition_state(ADMISSION_STATE_SHAPED);
    } else if (state == ADMISSION_STATE_SIEGE) {
        if (active <= (siege * 3) / 4) admission_transition_state(ADMISSION_STATE_GUARDED);
    }
}

/* ── Computational Leases ───────────────────────────────────────────── */

/** @brief Allocate and initialise a Computational Lease for the given @p path and @p method, adjusting budgets for the current admission state. */
OrbitAdmissionLease* orbit_admission_lease_create_for_route(const char* path, const char* method, OrbitArena* arena) {
    (void)method;
    __atomic_fetch_add(&orbit_admission_active_leases, 1, __ATOMIC_SEQ_CST);
    update_admission_state();

    orbit_perf_atomic_inc64(&orbit_perf_stats.admissions);

    OrbitAdmissionLease* lease = (OrbitAdmissionLease*)orbit_alloc(arena, sizeof(OrbitAdmissionLease));
    if (!lease) return NULL;
    memset(lease, 0, sizeof(OrbitAdmissionLease));
    /* Energy baseline (C4): cycles + attributable joules + completed-cycle
     * counter, so destroy() can attribute this lease's share. */
    lease->start_cycles = orbit_rdtsc();
    lease->start_total_cycles = (uint64_t)__atomic_load_n(&orbit_perf_stats.total_cycles, __ATOMIC_RELAXED);
    lease->start_joules = orbit_energy_attributable_joules();
    lease->joules = 0.0;

    /* Default route budgets — tightened below based on admission state. */
    lease->deadline_ns    = orbit_admission_now_ns() + 500ULL * 1000000ULL; /* 500 ms */
    lease->arena_limit    = 16 * 1024 * 1024; /* 16 MB */
    lease->request_limit  = 64 * 1024;         /* 64 KB */
    lease->response_limit = 2 * 1024 * 1024;  /* 2 MB */
    lease->db_queries_limit = 10;
    lease->db_steps_limit   = 100000;
    lease->flags = 0;

    OrbitAdmissionState cur_state = (OrbitAdmissionState)__atomic_load_n(&orbit_admission_state, __ATOMIC_RELAXED);

    /* SHAPED: halve the deadline, reduce DB step budget. */
    if (cur_state == ADMISSION_STATE_SHAPED) {
        lease->deadline_ns    = orbit_admission_now_ns() + 250ULL * 1000000ULL;
        lease->db_steps_limit = 50000;
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_throttled);
    } else if (cur_state == ADMISSION_STATE_GUARDED) {
        /* GUARDED: severely restrict CPU, memory, and database access. */
        lease->deadline_ns      = orbit_admission_now_ns() + 100ULL * 1000000ULL; /* 100 ms */
        lease->arena_limit      = 2 * 1024 * 1024; /* 2 MB */
        lease->db_queries_limit = 3;
        lease->db_steps_limit   = 10000;
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_throttled);
    } else if (cur_state == ADMISSION_STATE_SIEGE) {
        /* SIEGE: allow only health/auth/root routes with minimal budgets; reject everything else immediately. */
        bool is_critical = false;
        if (path && (strcmp(path, "/health") == 0 || strcmp(path, "/auth") == 0 || strcmp(path, "/") == 0)) {
            is_critical = true;
        }

        if (!is_critical) {
            /* Reject non-critical routes immediately. */
            lease->deadline_ns      = 0;
            lease->arena_limit      = 0;
            lease->db_queries_limit = 0;
            lease->db_steps_limit   = 0;
            lease->flags |= 1; /* REJECTED flag */
            orbit_perf_atomic_inc64(&orbit_perf_stats.admission_early_rejections);
        } else {
            /* Critical routes receive a minimal emergency budget. */
            lease->deadline_ns      = orbit_admission_now_ns() + 50ULL * 1000000ULL; /* 50 ms */
            lease->arena_limit      = 512 * 1024; /* 512 KB */
            lease->db_queries_limit = 2;
            lease->db_steps_limit   = 5000;
        }
    }

    /* Built-in sample override (documented in docs/ADMISSION.md): a route
     * literally named "/search" gets tighter budgets. Inert in the shipped
     * examples (none uses that path); kept as a visible lease-budget sample
     * until routes can declare their own budgets. */
    if (path) {
        if (strcmp(path, "/search") == 0) {
            lease->deadline_ns      = orbit_admission_now_ns() + 250ULL * 1000000ULL; /* 250 ms */
            lease->arena_limit      = 192 * 1024; /* 192 KB */
            lease->response_limit   = 1 * 1024 * 1024; /* 1 MB */
            lease->db_queries_limit = 4;
            lease->db_steps_limit   = 50000;
        }
    }

    current_lease = lease;
    return lease;
}

/** @brief Release a Computational Lease and decrement the active-lease counter, triggering an admission-state update. */
void orbit_admission_lease_destroy(OrbitAdmissionLease* lease) {
    if (lease == current_lease) {
        current_lease = NULL;
    }
    if (lease) {
        /* Per-lease energy attribution (ESTIMATE, same family as the
         * ledger's route split): package-joule delta over the lease
         * lifetime times this lease's share of completed-request cycles
         * in that window (own cycles included, so a lone request gets
         * share 1). Clamped to [0, delta]. Without a sensor every
         * accessor reads 0, so joules stays exactly 0 (cpu-proxy). */
        uint64_t end_cycles = orbit_rdtsc();
        uint64_t lease_cycles = (end_cycles >= lease->start_cycles)
            ? (end_cycles - lease->start_cycles) : 0;
        double dj = orbit_energy_attributable_joules() - lease->start_joules;
        if (dj < 0.0) dj = 0.0;
        uint64_t total_now = (uint64_t)__atomic_load_n(&orbit_perf_stats.total_cycles, __ATOMIC_RELAXED);
        uint64_t delta_total = (total_now >= lease->start_total_cycles)
            ? (total_now - lease->start_total_cycles) : 0;
        uint64_t denom = delta_total + lease_cycles;
        double share = (denom > 0) ? (double)lease_cycles / (double)denom : 0.0;
        if (share > 1.0) share = 1.0;
        lease->joules = dj * share;
    }
    __atomic_fetch_sub(&orbit_admission_active_leases, 1, __ATOMIC_SEQ_CST);
    update_admission_state();
}

/** @brief Release the request's lease, if it has one: the boundary answer's first step.
 *
 * A refused request still holds its lease, and the lease is what refused, so
 * the 503 the boundary sends must be built after this. The generated worker
 * loop calls it (runtime/arena.c has the mechanism; ENGINEERING.md section 7,
 * admission-lease-abort). This is a function rather than a direct
 * orbit_admission_lease_destroy because the generated C would otherwise have to
 * name current_lease, which unity builds declare and separate builds do not.
 */
void orbit_admission_lease_abandon(void) {
    if (current_lease) orbit_admission_lease_destroy(current_lease);
}

/** @brief Validate that the current lease's response-size and deadline budgets are not exceeded.  Returns false if any limit is hit. */
bool orbit_admission_lease_check_limits(size_t additional_response_bytes) {
    if (!current_lease) return true;

    // Check HTTP Response limit
    if (additional_response_bytes > 0) {
        if (current_lease->response_bytes + additional_response_bytes > current_lease->response_limit) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.admission_response_budget_exhausted);
            return false;
        }
        current_lease->response_bytes += additional_response_bytes;
    }

    // Check Monotonic Deadline
    if (orbit_admission_now_ns() > current_lease->deadline_ns) {
        orbit_perf_atomic_inc64(&orbit_perf_stats.admission_deadline_exhausted);
        return false;
    }

    return true;
}

/* ── SQLite Progress Handler Implementation ─────────────────────────── */

/** @brief SQLite progress-handler callback; aborts the query when the step budget or deadline is exceeded. */
int orbit_sqlite_progress_handler(void* param) {
    (void)param;
    if (current_lease) {
        current_lease->db_steps++;
        if (current_lease->db_steps > current_lease->db_steps_limit) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.admission_db_step_budget_exhausted);
            return 1; /* Abort SQLite query — step budget exceeded. */
        }
        if (orbit_admission_now_ns() > current_lease->deadline_ns) {
            orbit_perf_atomic_inc64(&orbit_perf_stats.admission_deadline_exhausted);
            return 1; /* Abort SQLite query — deadline elapsed. */
        }
    }
    return 0;
}

/* ── Compatibility Getters ──────────────────────────────────────────── */

/** @brief Return the lifetime count of admission checks performed. */
uint64_t orbit_admission_get_total_checks(void)  { return (uint64_t)__atomic_load_n(&orbit_admission_total_checks, __ATOMIC_RELAXED); }
/** @brief Return the lifetime count of requests blocked or banned. */
uint64_t orbit_admission_get_total_blocked(void) { return (uint64_t)__atomic_load_n(&orbit_admission_total_blocked, __ATOMIC_RELAXED); }
/** @brief Return whether admission is currently in siege mode. */
bool     orbit_admission_is_siege_mode(void)     { return __atomic_load_n(&admission_siege_active, __ATOMIC_RELAXED); }
/** @brief Suspicion score of @p ip_str; -1 when the IP is untracked. */
int orbit_admission_get_suspicion(const char* ip_str) {
    if (!ip_str) return -1;
    OrbitAdmissionIP ip;
    if (!admission_parse_ip(ip_str, &ip)) return -1;
    uint32_t shard_idx = admission_hash_ip(&ip) % ADMISSION_SHARD_COUNT;
    OrbitAdmissionShard* shard = &orbit_admission_shards[shard_idx];
    int score = -1;
    admission_lock_acquire(&shard->lock);
    for (int i = 0; i < ADMISSION_SLOTS_PER_SHARD; i++) {
        if (shard->entries[i].ip.family != 0 && admission_ip_eq(&shard->entries[i].ip, &ip)) {
            score = shard->entries[i].suspicion_score;
            break;
        }
    }
    admission_lock_release(&shard->lock);
    return score;
}
/** @brief Retry-After advice (ms) for the last deny on this thread. */
int orbit_admission_last_retry_ms(void) { return admission_tls_retry_ms; }
/** @brief ESTIMATE of joules attributed to @p lease (0 without a sensor). */
double orbit_admission_lease_joules(const OrbitAdmissionLease* lease) { return lease ? lease->joules : 0.0; }
/** @brief RDTSC cycles elapsed under @p lease (0 when the clock reads 0). */
uint64_t orbit_admission_lease_cycles(const OrbitAdmissionLease* lease) {
    if (!lease) return 0;
    uint64_t now = orbit_rdtsc();
    return (now >= lease->start_cycles) ? (now - lease->start_cycles) : 0;
}

#endif
