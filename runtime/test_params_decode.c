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
    printf("test_params_decode: PASSED\n");
    return 0;
}
