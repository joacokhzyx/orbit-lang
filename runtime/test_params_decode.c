/**
 * @file  test_params_decode.c
 * @brief Path params captured by orbit_route_match are percent-decoded.
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

int main(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    char req_text[128];
    strcpy(req_text,
        "GET /notes/hello%20world%2F123+a%2fb HTTP/1.1\r\n"
        "Host: localhost\r\n\r\n");

    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, req_text, strlen(req_text), &r, NULL);
    assert(c > 0);

    assert(orbit_route_match(arena, r, "GET", "/notes/:id") == true);
    const char* id = orbit_http_param_get(arena, r, "id");
    assert(strcmp(id, "hello world/123+a/b") == 0);

    orbit_arena_destroy(arena);

    /* A route with more captures than the old fixed slot table held. The
     * request owns its capture arrays now, so the count is the pattern's. */
    {
        char path[1024];
        char pattern[1024];
        char text[1200];
        int i;

        strcpy(pattern, "/x");
        strcpy(path, "/x");
        for (i = 0; i < 40; i++) {
            char seg[32];
            snprintf(seg, sizeof seg, "/:p%d", i);
            strcat(pattern, seg);
            snprintf(seg, sizeof seg, "/v%d", i);
            strcat(path, seg);
        }
        snprintf(text, sizeof text, "GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n", path);

        OrbitArena* big = orbit_arena_create(262144);
        assert(big != NULL);
        OrbitRequest* r2 = NULL;
        size_t c2 = orbit_http_parse_request_ex(big, text, strlen(text), &r2, NULL);
        assert(c2 > 0);
        assert(orbit_route_match(big, r2, "GET", pattern) == true);
        assert(r2->param_count == 40);
        assert(strcmp(orbit_http_param_get(big, r2, "p39"), "v39") == 0);
        orbit_arena_destroy(big);
    }

    printf("test_params_decode: PASSED\n");
    return 0;
}
