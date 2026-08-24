#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>

#include "runtime.h"

int main(void) {
    const char* req1 = "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}";
    const char* req2 = "POST /register HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}";

    size_t l1 = strlen(req1);
    size_t l2 = strlen(req2);

    char* buf = (char*)malloc(l1 + l2);
    assert(buf != NULL);
    memcpy(buf, req1, l1);
    memcpy(buf + l1, req2, l2);

    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    /* First request of a pipelined pair. */
    OrbitRequest* r1 = NULL;
    size_t c1 = orbit_http_parse_request_ex(arena, buf, l1 + l2, &r1, NULL);
    assert(r1 != NULL);
    assert(c1 == l1);
    assert(strcmp(r1->method, "POST") == 0);
    assert(strcmp(r1->path, "/login") == 0);
    assert(r1->body_len == 2);
    assert(r1->body != NULL);
    assert(memcmp(r1->body, "{}", 2) == 0);
    assert(r1->body[2] == '\0');

    /* Regression: the parser used to write '\0' at consumed + content_length
     * into the shared read buffer, clobbering the first byte of the next
     * pipelined request ("POST" here, at buf[l1]). That byte must be intact. */
    assert(buf[l1] == 'P');
    assert(buf[l1 + 1] == 'O');

    /* Second request starts exactly at the end of the first. */
    OrbitRequest* r2 = NULL;
    size_t c2 = orbit_http_parse_request_ex(arena, buf + c1, l1 + l2 - c1, &r2, NULL);
    assert(r2 != NULL);
    assert(c2 == l2);
    assert(strcmp(r2->method, "POST") == 0);
    assert(strcmp(r2->path, "/register") == 0);
    assert(r2->body_len == 2);
    assert(r2->body != NULL);
    assert(memcmp(r2->body, "{}", 2) == 0);

    /* GET without Content-Length consumes the header block only. The parser
     * null-terminates method/path in place, so the buffer must be mutable. */
    const char* get_src = "GET /loop HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    size_t glen = strlen(get_src);
    char* get = (char*)malloc(glen);
    assert(get != NULL);
    memcpy(get, get_src, glen);
    OrbitRequest* r3 = NULL;
    size_t c3 = orbit_http_parse_request_ex(arena, get, glen, &r3, NULL);
    assert(r3 != NULL);
    assert(c3 == glen);
    assert(strcmp(r3->method, "GET") == 0);
    assert(strcmp(r3->path, "/loop") == 0);
    assert(r3->body_len == 0);
    assert(r3->body == NULL);
    free(get);

    orbit_arena_destroy(arena);
    free(buf);

    printf("http parse pipelined tests: PASSED\n");
    return 0;
}