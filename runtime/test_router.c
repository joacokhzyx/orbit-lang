/**
 * @file  test_router.c
 * @brief Route table a backend with no C emitter registers into.
 *
 * Pins the dispatch order the emitted chain uses: every exact path before
 * any pattern, the shared matcher for patterns, the captures that matcher
 * fills, and NULL when nothing owns the path. A backend that emits no C
 * cannot call the emitted chain, so this table is the only thing between its
 * handlers and a 404; the order it picks has to be the same one.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

static OrbitAdmissionConfig make_cfg(int rate, int win_ms, int burst,
                                int ban, int inc, int dec) {
    OrbitAdmissionConfig c;
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

static OrbitRequest* parse(OrbitArena* arena, const char* method, const char* path) {
    char raw[512];
    snprintf(raw, sizeof(raw), "%s %s HTTP/1.1\r\nHost: localhost\r\n\r\n", method, path);
    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, raw, strlen(raw), &r, NULL);
    assert(c > 0 && r != NULL);
    return r;
}

static OrbitResponse* answer(OrbitArena* arena, const char* body) {
    return orbit_response_create(arena, 200, "text/plain", body);
}

static OrbitResponse* handle_exact(OrbitArena* arena, OrbitRequest* req) {
    (void)req;
    return answer(arena, "exact");
}

static OrbitResponse* handle_param(OrbitArena* arena, OrbitRequest* req) {
    return answer(arena, orbit_http_param_get(arena, req, "id"));
}

static OrbitResponse* handle_wild(OrbitArena* arena, OrbitRequest* req) {
    (void)req;
    return answer(arena, "wild");
}

static void check_body(OrbitArena* arena, OrbitRequest* req, const char* want) {
    OrbitResponse* res = orbit_router_dispatch(arena, req);
    assert(res != NULL);
    assert(strcmp(res->body, want) == 0);
}

/* Registration order must not decide the owner: the pattern goes in first
 * and the exact path still answers for itself. */
static void test_exact_beats_pattern(void) {
    orbit_router_reset();
    orbit_router_register("GET", "/users/:id", 0, 0, 0, handle_param);
    orbit_router_register("GET", "/users/me", 0, 0, 0, handle_exact);
    assert(orbit_router_count() == 2);

    OrbitArena* arena = orbit_arena_create(65536);
    check_body(arena, parse(arena, "GET", "/users/me"), "exact");
    check_body(arena, parse(arena, "GET", "/users/42"), "42");
    orbit_arena_destroy(arena);
}

/* The method is part of the key: a POST to a GET route belongs to nobody. */
static void test_method_is_part_of_the_key(void) {
    orbit_router_reset();
    orbit_router_register("GET", "/thing", 0, 0, 0, handle_exact);
    OrbitArena* arena = orbit_arena_create(65536);
    assert(orbit_router_dispatch(arena, parse(arena, "POST", "/thing")) == NULL);
    assert(orbit_router_dispatch(arena, parse(arena, "GET", "/other")) == NULL);
    orbit_arena_destroy(arena);
}

/* A wildcard is one segment here too, because the matcher is the router's. */
static void test_wildcard_is_one_segment(void) {
    orbit_router_reset();
    orbit_router_register("GET", "/files/*", 0, 0, 0, handle_wild);
    OrbitArena* arena = orbit_arena_create(65536);
    check_body(arena, parse(arena, "GET", "/files/a"), "wild");
    assert(orbit_router_dispatch(arena, parse(arena, "GET", "/files/a/b")) == NULL);
    orbit_arena_destroy(arena);
}

/* A limit declaration reaches the shared admission table under the path the
 * program wrote; it is not a field only this table keeps. */
static void test_limit_reaches_admission(void) {
    orbit_router_reset();
    orbit_admission_reset();
    orbit_admission_init(make_cfg(1000000, 1000, 1000000, 1000000, 10, 1));
    orbit_router_register("GET", "/limited", 1, 1000, 1, handle_exact);
    const char* ip = "10.9.9.20";
    assert(orbit_admission_check_route(ip, "GET", "/limited") == true);
    assert(orbit_admission_check_route(ip, "GET", "/limited") == false);
    orbit_router_reset();
    assert(orbit_router_count() == 0);
}

int main(void) {
    printf("test_router\n");
    fflush(stdout);
    RUN_TEST(test_exact_beats_pattern);
    RUN_TEST(test_method_is_part_of_the_key);
    RUN_TEST(test_wildcard_is_one_segment);
    RUN_TEST(test_limit_reaches_admission);
    printf("test_router: PASSED\n");
    return 0;
}
