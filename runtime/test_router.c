/* Exercises the immutable route image consumed by the native server. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"
#include "http_native.c"

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
    char head[512];
    snprintf(head, sizeof(head), "%s %s HTTP/1.1\r\nHost: localhost\r\n\r\n", method, path);
    size_t n = strlen(head);
    /* The request's method, path and headers point into the buffer it was
     * parsed from (http.h), so that buffer has to outlive the request. A stack
     * buffer here survived on Windows by luck: the matcher read a dead path on
     * Linux and dispatch answered 404 for a route that exists. */
    char* raw = (char*)orbit_alloc(arena, n + 1);
    assert(raw != NULL);
    memcpy(raw, head, n + 1);
    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, raw, n, &r, NULL);
    assert(c > 0 && r != NULL);
    return r;
}

typedef struct {
    const char* path;
    unsigned kind;
    unsigned rate;
} TestRoute;

static void put_route_word(unsigned char* entry, unsigned field, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) entry[field * 4 + i] = (unsigned char)(value >> (8 * i));
}

static OrbitNativeService build_service(unsigned char* image, size_t capacity,
                                        const TestRoute* routes, size_t count) {
    size_t offset = count * ORBIT_NATIVE_ROUTE_WORDS * 4;
    size_t method = offset;
    assert(offset + sizeof("GET") <= capacity);
    memcpy(image + offset, "GET", sizeof("GET"));
    offset += sizeof("GET");
    for (size_t i = 0; i < count; i++) {
        unsigned char* entry = image + i * ORBIT_NATIVE_ROUTE_WORDS * 4;
        size_t length = strlen(routes[i].path) + 1;
        assert(offset + length <= capacity);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_METHOD, (uint32_t)method);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_PATH, (uint32_t)offset);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_RATE, routes[i].rate);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_BURST, routes[i].rate);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_WINDOW, routes[i].rate ? 1000 : 0);
        put_route_word(entry, ORBIT_NATIVE_ROUTE_KIND, routes[i].kind);
        memcpy(image + offset, routes[i].path, length);
        offset += length;
    }
    return (OrbitNativeService){.routes = image, .count = count, .admission = true};
}

static void test_exact_beats_pattern(void) {
    const TestRoute routes[] = {{"/users/me", 0, 0}, {"/users/:id", 1, 0}};
    unsigned char image[256];
    OrbitNativeService service = build_service(image, sizeof image, routes, 2);
    OrbitArena* arena = orbit_arena_create(65536);
    assert(native_find_route(&service, arena, parse(arena, "GET", "/users/me")) == 0);
    OrbitRequest* request = parse(arena, "GET", "/users/42");
    assert(native_find_route(&service, arena, request) == 1);
    assert(strcmp(orbit_http_param_get(arena, request, "id"), "42") == 0);
    orbit_arena_destroy(arena);
}

static void test_method_is_part_of_the_key(void) {
    const TestRoute routes[] = {{"/thing", 0, 0}};
    unsigned char image[128];
    OrbitNativeService service = build_service(image, sizeof image, routes, 1);
    OrbitArena* arena = orbit_arena_create(65536);
    assert(native_find_route(&service, arena, parse(arena, "POST", "/thing")) == SIZE_MAX);
    assert(native_find_route(&service, arena, parse(arena, "GET", "/other")) == SIZE_MAX);
    orbit_arena_destroy(arena);
}

static void test_wildcard_is_one_segment(void) {
    const TestRoute routes[] = {{"/files/*", 1, 0}};
    unsigned char image[128];
    OrbitNativeService service = build_service(image, sizeof image, routes, 1);
    OrbitArena* arena = orbit_arena_create(65536);
    assert(native_find_route(&service, arena, parse(arena, "GET", "/files/a")) == 0);
    assert(native_find_route(&service, arena, parse(arena, "GET", "/files/a/b")) == SIZE_MAX);
    orbit_arena_destroy(arena);
}

static void test_limit_reaches_admission(void) {
    const TestRoute routes[] = {{"/limited", 0, 1}};
    unsigned char image[128];
    OrbitNativeService service = build_service(image, sizeof image, routes, 1);
    orbit_admission_reset();
    orbit_admission_init(make_cfg(1000000, 1000, 1000000, 1000000, 10, 1));
    native_register_limits(&service);
    const char* ip = "10.9.9.20";
    assert(orbit_admission_check_route(ip, "GET", "/limited") == true);
    assert(orbit_admission_check_route(ip, "GET", "/limited") == false);
    orbit_admission_cleanup();
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
