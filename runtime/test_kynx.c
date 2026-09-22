/* Kynx 0.1 property tests: token bucket, zero false bans, IPv6 identity,
 * per-route limits, lease energy, pool-fraction admission.
 *
 * Compiled with -DORBIT_KYNX_TEST so kynx.c reads orbit_kynx_test_now_ns
 * (defined here) instead of the wall clock: every test steps time exactly.
 *
 *   gcc -O0 -w -I runtime -I runtime/vendor -DORBIT_WITH_NET -DORBIT_KYNX_TEST \
 *       runtime/test_kynx.c -o t_kynx_bin [-lws2_32]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>

#include "runtime.h"

uint64_t orbit_kynx_test_now_ns = 1000000000ULL; /* t0 = 1s */

static int g_passed = 0;

static void step_ms(uint64_t ms) {
    orbit_kynx_test_now_ns += ms * 1000000ULL;
}

static OrbitKynxConfig make_cfg(int rate, int win_ms, int burst,
                                int ban, int inc, int dec) {
    OrbitKynxConfig c;
    memset(&c, 0, sizeof(c));
    c.pool_size = 512;
    c.rate_limit = rate;
    c.window_ms = win_ms;
    c.burst = burst;
    c.ban_threshold = ban;
    c.score_increment = inc;
    c.score_decay = dec;
    c.enabled = true;
    return c;
}

/* T1: a client at (or under) its sustained rate is NEVER denied and never
 * accumulates suspicion — over many windows. This is the zero-false-ban
 * property the old window-counter bug violated (~70 reqs). */
static void test_legit_client_never_denied(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(10, 1000, 10, 200, 10, 1));
    int admits = 0;
    for (int i = 0; i < 300; i++) { /* 30s at 8.3 rps vs limit 10 rps */
        if (orbit_kynx_check("10.0.0.1")) admits++;
        step_ms(120);
    }
    assert(admits == 300);
    assert(orbit_kynx_get_suspicion("10.0.0.1") == 0);
    assert(orbit_kynx_get_total_blocked() == 0);
    printf("T1 legit client never denied: PASSED\n");
    g_passed++;
}

/* T2: bucket capacity = burst; denies carry a sane Retry-After and the
 * next token arrives when Retry-After said it would. */
static void test_burst_capacity_and_retry(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(5, 1000, 5, 200, 10, 1));
    const char* ip = "10.0.0.2";
    int admits = 0;
    for (int i = 0; i < 5; i++) { /* full bucket of 5 */
        if (orbit_kynx_check(ip)) admits++;
        else assert(0);
    }
    assert(!orbit_kynx_check(ip)); /* 6th instant request denied */
    int ra = orbit_kynx_last_retry_ms();
    assert(ra > 0 && ra <= 1000);
    /* Exactly one token after ra milliseconds: admit again. */
    step_ms((uint64_t)ra);
    assert(orbit_kynx_check(ip) == true);
    assert(!orbit_kynx_check(ip));
    printf("T2 burst capacity + Retry-After: PASSED\n");
    g_passed++;
}

/* T3: a single accidental burst scores ONE violation unit (not one per
 * denied request) and never bans; clean traffic then decays the score
 * back to zero within score_decay windows. */
static void test_burst_is_one_violation_then_decays(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1, 1000, 1, 200, 10, 1));
    const char* ip = "10.0.0.3";
    assert(orbit_kynx_check(ip)); /* spends the single-token bucket */
    for (int i = 0; i < 100; i++) { /* same-instant flood */
        assert(orbit_kynx_check(ip) == false);
    }
    assert(orbit_kynx_get_suspicion(ip) == 10); /* ONE window, +10 only */
    assert(orbit_kynx_get_total_blocked() == 100);
    /* Clean 1 rps for 15 windows: score walks 10 -> 0. */
    int scored_max = 10;
    for (int i = 0; i < 15; i++) {
        step_ms(1000);
        assert(orbit_kynx_check(ip) == true);
        int s = orbit_kynx_get_suspicion(ip);
        if (s < scored_max) scored_max = s;
    }
    assert(orbit_kynx_get_suspicion(ip) == 0);
    printf("T3 burst = 1 violation, decays to 0: PASSED\n");
    g_passed++;
}

/* T4: sustained abuse across violation windows DOES reach the ban, stays
 * banned for 5 minutes, then recovers with a halved score. */
static void test_sustained_abuse_bans_and_recovers(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1, 1000, 1, 20, 10, 1));
    const char* ip = "10.0.0.4";
    assert(orbit_kynx_check(ip));
    int banned_at = -1;
    for (int w = 1; w <= 10 && banned_at < 0; w++) {
        step_ms(1000);
        /* every window: one admit (refill 1 token), then flood denies */
        assert(orbit_kynx_check(ip) == true);
        for (int d = 0; d < 5; d++) assert(orbit_kynx_check(ip) == false);
        if (orbit_kynx_get_suspicion(ip) >= 20) banned_at = w;
    }
    assert(banned_at == 3); /* w1: +10=10; w2: decay -1 then +10=19;
                             * w3: decay -1 then +10=28 >= 20 -> ban */
    assert(orbit_kynx_check(ip) == false);
    assert(orbit_kynx_last_retry_ms() > 0);
    /* Still banned at 4m59s. */
    step_ms(299000);
    assert(orbit_kynx_check(ip) == false);
    /* Past 5 minutes: unbanned (28/2=14), that same admit decays -1. */
    step_ms(2000);
    assert(orbit_kynx_check(ip) == true);
    int s = orbit_kynx_get_suspicion(ip);
    assert(s == 13);
    printf("T4 sustained abuse bans after threshold, recovers: PASSED\n");
    g_passed++;
}

/* T5: table stays bounded under an IP flood (oldest eviction, no growth
 * past 1024 shards x 64 slots). */
static void test_memory_bounded(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1000000, 1000, 1000000, 200, 10, 1));
    /* reset() clears the table but not the perf gauge: measure the delta. */
    uint32_t base = orbit_perf_stats.kynx_tracked_ips;
    char buf[32];
    for (int i = 0; i < 100000; i++) {
        snprintf(buf, sizeof(buf), "10.%d.%d.%d",
                 (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF);
        assert(orbit_kynx_check(buf) == true);
    }
    uint32_t delta = orbit_perf_stats.kynx_tracked_ips - base;
    assert(delta <= (uint32_t)(1024 * 64));
    printf("T5 memory bounded under 100k IP flood: PASSED\n");
    g_passed++;
}

/* T6: IPv6 text forms of the same address share one entry (violation
 * state visible under both spellings); different addresses do not. */
static void test_ipv6_identity(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1, 1000, 1, 200, 10, 1));
    const char* short_form = "2001:db8::1";
    const char* full_form  = "2001:0db8:0000:0000:0000:0000:0000:0001";
    assert(orbit_kynx_check(short_form)); /* insert */
    assert(orbit_kynx_get_suspicion(full_form) == 0); /* same entry */
    assert(orbit_kynx_check(short_form) == false); /* violate */
    assert(orbit_kynx_get_suspicion(full_form) == 10); /* shared state */
    assert(orbit_kynx_get_suspicion("2001:db8::2") == -1); /* distinct */
    assert(orbit_kynx_check("::1") == true); /* loopback parses, inserts */
    assert(orbit_kynx_check("fe80::1") == true);
    assert(orbit_kynx_check("::ffff:192.0.2.1") == true); /* v4-mapped */
    assert(orbit_kynx_check("1::2::3") == true); /* malformed: fail open */
    assert(orbit_kynx_check("gg::1") == true);    /* fail open */
    printf("T6 IPv6 identity + fail-open: PASSED\n");
    g_passed++;
}

/* T7: IPv4-mapped equality — ::ffff:10.0.0.9 and 10.0.0.9 are different
 * bytes under inet_ntop but must not corrupt state; each gets its own
 * bucket (documented: identity is the exact address string's bytes). */
static void test_retry_monotone(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(2, 1000, 2, 200, 10, 1));
    const char* ip = "10.0.0.9";
    assert(orbit_kynx_check(ip));
    assert(orbit_kynx_check(ip));
    assert(!orbit_kynx_check(ip));
    int ra1 = orbit_kynx_last_retry_ms();
    step_ms((uint64_t)ra1 / 2);
    assert(!orbit_kynx_check(ip)); /* still empty: Retry-After not reached */
    int ra2 = orbit_kynx_last_retry_ms();
    assert(ra2 <= ra1); /* closer to the next token */
    step_ms((uint64_t)ra2 + 1);
    assert(orbit_kynx_check(ip) == true);
    printf("T7 Retry-After monotone and honored: PASSED\n");
    g_passed++;
}

/* T8: disabled Kynx admits everything (kill switch). */
static void test_disabled_fails_open(void) {
    orbit_kynx_reset();
    OrbitKynxConfig c = make_cfg(1, 1000, 1, 10, 10, 1);
    c.enabled = false;
    orbit_kynx_init(c);
    for (int i = 0; i < 1000; i++) {
        assert(orbit_kynx_check("10.1.1.1") == true);
    }
    assert(orbit_kynx_get_total_checks() == 0);
    printf("T8 disabled = fail open: PASSED\n");
    g_passed++;
}

/* T9: X-Forwarded-For is honored ONLY from trusted peers; untrusted peers
 * can never spoof a client identity, and add_header serializes Retry-After. */
static void test_effective_ip_and_header(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(10, 1000, 10, 200, 10, 1));
    char out[64];

    /* No trusted proxies: XFF is ignored entirely. */
    orbit_kynx_effective_ip("203.0.113.9", "1.2.3.4, 5.6.7.8", out, sizeof(out));
    assert(strcmp(out, "203.0.113.9") == 0);
    assert(!orbit_kynx_is_trusted_proxy("10.0.0.5"));

    /* Trust one proxy CIDR; XFF rightmost non-trusted hop wins. */
    orbit_kynx_add_trusted_proxy("10.0.0.0/8");
    assert(orbit_kynx_is_trusted_proxy("10.1.2.3"));
    assert(!orbit_kynx_is_trusted_proxy("11.0.0.1"));
    orbit_kynx_effective_ip("10.0.0.5", "203.0.113.7, 10.9.9.9", out, sizeof(out));
    assert(strcmp(out, "203.0.113.7") == 0);
    /* All hops trusted -> keep the peer. */
    orbit_kynx_effective_ip("10.0.0.5", "10.1.1.1, 10.2.2.2", out, sizeof(out));
    assert(strcmp(out, "10.0.0.5") == 0);
    /* Untrusted peer with XFF: spoof attempt ignored. */
    orbit_kynx_effective_ip("198.51.100.1", "203.0.113.7", out, sizeof(out));
    assert(strcmp(out, "198.51.100.1") == 0);
    /* IPv6 trusted network. */
    orbit_kynx_add_trusted_proxy("2001:db8::/32");
    assert(orbit_kynx_is_trusted_proxy("2001:db8:aaaa::1"));
    assert(!orbit_kynx_is_trusted_proxy("2001:db9::1"));

    /* Response extra headers (Retry-After wire shape). */
    OrbitArena* arena = orbit_arena_create(64 * 1024);
    assert(arena != NULL);
    OrbitResponse* res = orbit_response_create(arena, 429, "text/plain", "slow down");
    assert(res != NULL && res->extra_headers == NULL);
    orbit_response_add_header(arena, res, "Retry-After", "2");
    assert(res->extra_headers != NULL);
    assert(strcmp(res->extra_headers, "Retry-After: 2\r\n") == 0);
    assert(res->extra_headers_len == strlen(res->extra_headers));
    orbit_response_add_header(arena, res, "X-Test", "1");
    assert(strcmp(res->extra_headers, "Retry-After: 2\r\nX-Test: 1\r\n") == 0);
    orbit_arena_destroy(arena);
    printf("T9 trusted XFF + Retry-After header: PASSED\n");
    g_passed++;
}

/* T10: per-route rate limit — annotated route has its own bucket; a
 * second route is unaffected; unannotated traffic uses only the global
 * bucket; route deny never raises suspicion (zero-false-ban). */
static void test_route_limit(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1000, 1000, 1000, 200, 10, 1)); /* global huge */
    orbit_kynx_register_route_limit("GET", "/api/heavy", 2, 1000, 2);
    orbit_kynx_register_route_limit("GET", "/api/other/:id", 100, 1000, 100);

    const char* ip = "10.9.9.9";
    assert(orbit_kynx_check_route(ip, "GET", "/api/heavy") == true);
    assert(orbit_kynx_check_route(ip, "GET", "/api/heavy") == true);
    assert(orbit_kynx_check_route(ip, "GET", "/api/heavy") == false);
    int ra = orbit_kynx_last_retry_ms();
    assert(ra > 0 && ra <= 1000);
    assert(orbit_kynx_get_suspicion(ip) == 0); /* no score from route deny */

    /* Different route: unaffected. */
    assert(orbit_kynx_check_route(ip, "GET", "/api/other/42") == true);
    /* Path param pattern matches. */
    assert(orbit_kynx_check_route(ip, "GET", "/api/other/99") == true);

    /* Unannotated path falls through to global (huge → allow). */
    assert(orbit_kynx_check_route(ip, "GET", "/plain") == true);

    /* Global still works independently. */
    assert(orbit_kynx_check(ip) == true);

    /* After refill window, heavy admits again. */
    step_ms(600);
    assert(orbit_kynx_check_route(ip, "GET", "/api/heavy") == true);
    printf("T10 per-route limit + zero false ban: PASSED\n");
    g_passed++;
}

/* T11: the lease carries an energy baseline at creation and an attributed
 * ESTIMATE at destroy. This box has no RAPL sensor, so joules must read
 * exactly 0 (cpu-proxy: cycles are a proxy, never converted to joules). */
static void test_lease_energy(void) {
    orbit_kynx_reset();
    orbit_kynx_init(make_cfg(1000, 1000, 1000, 200, 10, 1));
    assert(orbit_energy_has_sensor() == 0);
    assert(strcmp(orbit_energy_source(), "cpu-proxy") == 0);
    OrbitArena* arena = orbit_arena_create(64 * 1024);
    assert(arena != NULL);
    OrbitKynxLease* lease = orbit_kynx_lease_create_for_route("/heavy", "GET", arena);
    assert(lease != NULL);
    assert(lease->joules == 0.0);
    assert(orbit_kynx_lease_joules(lease) == 0.0);
    orbit_kynx_lease_destroy(lease);
    assert(lease->joules == 0.0);
    assert(orbit_kynx_lease_joules(lease) == 0.0);
    assert(orbit_kynx_lease_joules(NULL) == 0.0);
    assert(orbit_kynx_lease_cycles(NULL) == 0);
    orbit_arena_destroy(arena);
    printf("T11 lease energy attribution (cpu-proxy reads 0): PASSED\n");
    g_passed++;
}

/* T12: admission tiers are fractions of pool_size (SHAPED pool/16,
 * GUARDED pool/4, SIEGE pool; release at 3/4). pool=64 walks every tier
 * by live lease count; pool=0 keeps the legacy absolute scale. */
static void test_pool_fraction_states(void) {
    orbit_kynx_reset();
    OrbitKynxConfig c = make_cfg(1000000, 1000, 1000000, 1000000, 10, 1);
    c.pool_size = 64;
    orbit_kynx_init(c);
    OrbitArena* arena = orbit_arena_create(64 * 1024);
    assert(arena != NULL);
    OrbitKynxLease* held[80];
    int n = 0;
    /* 1 active: STABLE, full 500 ms budget. */
    held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    assert((held[0]->flags & 1) == 0);
    assert(held[0]->deadline_ns == orbit_kynx_test_now_ns + 500ULL * 1000000ULL);
    /* 6 active > 4: SHAPED, 250 ms. */
    for (int i = 0; i < 4; i++) held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    assert(held[n - 1]->deadline_ns == orbit_kynx_test_now_ns + 250ULL * 1000000ULL);
    /* 18 active > 16: GUARDED, 100 ms. */
    for (int i = 0; i < 11; i++) held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    assert(held[n - 1]->deadline_ns == orbit_kynx_test_now_ns + 100ULL * 1000000ULL);
    /* 65 active > 64: SIEGE, non-critical rejected. The rejected lease is
     * destroyed at once, mirroring the server's 503 path: a rejected lease
     * carries a zero arena budget and must never stay current, or later
     * allocations on any arena would fail. */
    for (int i = 0; i < 46; i++) held[n++] = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    OrbitKynxLease* rej = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    assert(rej != NULL);
    assert(rej->flags & 1);
    assert(orbit_kynx_is_siege_mode() == true);
    orbit_kynx_lease_destroy(rej);
    OrbitKynxLease* crit = orbit_kynx_lease_create_for_route("/health", "GET", arena);
    assert(crit != NULL);
    assert((crit->flags & 1) == 0);
    orbit_kynx_lease_destroy(crit);
    /* Drain everything: hysteresis cascades back to STABLE. */
    for (int i = 0; i < n; i++) orbit_kynx_lease_destroy(held[i]);
    assert(orbit_kynx_is_siege_mode() == false);
    OrbitKynxLease* calm = orbit_kynx_lease_create_for_route("/x", "GET", arena);
    assert(calm->deadline_ns == orbit_kynx_test_now_ns + 500ULL * 1000000ULL);
    orbit_kynx_lease_destroy(calm);
    orbit_arena_destroy(arena);
    /* pool_size 0 keeps the historical absolute scale (SHAPED above 32). */
    orbit_kynx_reset();
    OrbitKynxConfig c0 = make_cfg(1000000, 1000, 1000000, 1000000, 10, 1);
    c0.pool_size = 0;
    orbit_kynx_init(c0);
    OrbitArena* arena0 = orbit_arena_create(64 * 1024);
    assert(arena0 != NULL);
    OrbitKynxLease* h0[40];
    for (int i = 0; i < 34; i++) h0[i] = orbit_kynx_lease_create_for_route("/x", "GET", arena0);
    assert(h0[31]->deadline_ns == orbit_kynx_test_now_ns + 500ULL * 1000000ULL);
    assert(h0[33]->deadline_ns == orbit_kynx_test_now_ns + 250ULL * 1000000ULL);
    for (int i = 0; i < 34; i++) orbit_kynx_lease_destroy(h0[i]);
    orbit_arena_destroy(arena0);
    printf("T12 pool-fraction admission states: PASSED\n");
    g_passed++;
}

int main(void) {
    test_legit_client_never_denied();
    test_burst_capacity_and_retry();
    test_burst_is_one_violation_then_decays();
    test_sustained_abuse_bans_and_recovers();
    test_memory_bounded();
    test_ipv6_identity();
    test_retry_monotone();
    test_disabled_fails_open();
    test_effective_ip_and_header();
    test_route_limit();
    test_lease_energy();
    test_pool_fraction_states();
    printf("kynx 0.1 property tests: %d/12 PASSED\n", g_passed);
    return g_passed == 12 ? 0 : 1;
}
