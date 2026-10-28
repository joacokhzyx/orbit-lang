#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>

#include "runtime.h"

#ifdef _WIN32
#define SET_ENV(n, v) _putenv_s((n), (v))
#else
#define SET_ENV(n, v) setenv((n), (v), 1)
#endif

/* Parse a copy of text[0..len) in a buffer of exactly that size, so a read
 * past the end is a fault under a checker and not silently a NUL. */
static size_t parse_copy(OrbitArena* arena, const char* text, size_t len, OrbitRequest** req, int* perr) {
    char* b = (char*)malloc(len ? len : 1);
    assert(b != NULL);
    memcpy(b, text, len);
    *perr = 0;
    size_t n = orbit_http_parse_request_ex(arena, b, len, req, perr);
    free(b);
    return n;
}

static char* repeat(char c, size_t n) {
    char* p = (char*)malloc(n + 1);
    assert(p != NULL);
    memset(p, c, n);
    p[n] = '\0';
    return p;
}

/* Request line, header and body caps: 414, 431, 413, plus a malformed
 * Content-Length (400). Each is answered from the raw bytes, with the arena
 * untouched, and each has a control just inside the cap. */
static void test_http_limits(void) {
    OrbitArena* arena = orbit_arena_create(4 * 1024 * 1024);
    assert(arena != NULL);
    orbit_http_limits_reload();
    OrbitRequest* rq = NULL;
    int perr = 0;

    /* Request line: 8192 bytes is the last accepted, 8193 is 414. */
    {
        size_t base = strlen("GET / HTTP/1.1");
        size_t k_ok = 8192 - base;
        char* pad = repeat('a', k_ok);
        char* ok = (char*)malloc(k_ok + 64);
        sprintf(ok, "GET /%s HTTP/1.1\r\nHost: x\r\n\r\n", pad);
        assert(strcspn(ok, "\r") == 8192);
        size_t n = parse_copy(arena, ok, strlen(ok), &rq, &perr);
        assert(perr == 0 && rq != NULL && n == strlen(ok));
        free(ok);
        free(pad);

        char* pad2 = repeat('a', k_ok + 1);
        char* bad = (char*)malloc(k_ok + 64);
        sprintf(bad, "GET /%s HTTP/1.1\r\nHost: x\r\n\r\n", pad2);
        assert(strcspn(bad, "\r") == 8193);
        size_t before = orbit_arena_used(arena);
        n = parse_copy(arena, bad, strlen(bad), &rq, &perr);
        assert(perr == 2 && rq == NULL && n == strlen(bad));
        assert(orbit_arena_used(arena) == before);
        /* A line that never ends is refused at the cap, not awaited. */
        char* endless = repeat('a', 9000);
        parse_copy(arena, endless, 9000, &rq, &perr);
        assert(perr == 2 && rq == NULL);
        free(endless);
        free(bad);
        free(pad2);
    }

    /* Header count: 100 lines accepted, 101 is 431. */
    {
        char* h = (char*)malloc(8192);
        for (int count = 100; count <= 101; count++) {
            char* p = h;
            p += sprintf(p, "GET / HTTP/1.1\r\n");
            for (int i = 0; i < count; i++) p += sprintf(p, "X-%d: v\r\n", i);
            p += sprintf(p, "\r\n");
            size_t before = orbit_arena_used(arena);
            size_t n = parse_copy(arena, h, (size_t)(p - h), &rq, &perr);
            if (count == 100) {
                assert(perr == 0 && rq != NULL && n == (size_t)(p - h));
            } else {
                assert(perr == 3 && rq == NULL);
                assert(orbit_arena_used(arena) == before);
            }
        }
        free(h);
    }

    /* Header bytes: 64 KiB total. Over it is 431 with or without the
     * terminator, so an unfinished head is refused while it is still open. */
    {
        size_t big = 70000;
        char* val = repeat('v', big);
        char* h = (char*)malloc(big + 64);
        int hl = sprintf(h, "GET / HTTP/1.1\r\nX-Big: %s\r\n\r\n", val);
        size_t before = orbit_arena_used(arena);
        parse_copy(arena, h, (size_t)hl, &rq, &perr);
        assert(perr == 3 && rq == NULL);
        hl -= 4; /* drop the blank line: head still open */
        parse_copy(arena, h, (size_t)hl, &rq, &perr);
        assert(perr == 3 && rq == NULL);
        assert(orbit_arena_used(arena) == before);
        /* Control: 60000 bytes of header is fine. */
        char* val2 = repeat('v', 60000);
        char* h2 = (char*)malloc(60100);
        int h2l = sprintf(h2, "GET / HTTP/1.1\r\nX-Big: %s\r\n\r\n", val2);
        size_t n = parse_copy(arena, h2, (size_t)h2l, &rq, &perr);
        assert(perr == 0 && rq != NULL && n == (size_t)h2l);
        free(h2); free(val2); free(h); free(val);
    }

    /* Body: refused on the header alone (no body bytes sent), and the
     * arena does not move. The cap itself is accepted. */
    {
        const char* over = "POST /u HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n";
        size_t before = orbit_arena_used(arena);
        parse_copy(arena, over, strlen(over), &rq, &perr);
        assert(perr == 4 && rq == NULL);
        assert(orbit_arena_used(arena) == before);
        const char* huge = "POST /u HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n";
        parse_copy(arena, huge, strlen(huge), &rq, &perr);
        assert(perr == 4 && rq == NULL);

        size_t body = 1048576;
        const char* head = "POST /u HTTP/1.1\r\nContent-Length: 1048576\r\n\r\n";
        size_t hl = strlen(head);
        char* msg = (char*)malloc(hl + body);
        memcpy(msg, head, hl);
        memset(msg + hl, 'b', body);
        size_t n = parse_copy(arena, msg, hl + body, &rq, &perr);
        assert(perr == 0 && rq != NULL && rq->body_len == body && n == hl + body);
        free(msg);
    }

    /* Malformed or conflicting Content-Length is 400, never read as 0. */
    {
        const char* bad[] = {
            "POST /u HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
            "POST /u HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST /u HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx",
        };
        for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
            parse_copy(arena, bad[i], strlen(bad[i]), &rq, &perr);
            assert(perr == 5 && rq == NULL);
        }
        /* Control: the same length twice is not a conflict. */
        const char* same = "POST /u HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nxx";
        parse_copy(arena, same, strlen(same), &rq, &perr);
        assert(perr == 0 && rq != NULL && rq->body_len == 2);
    }

    /* The refusal codes map to the statuses the server sends. */
    {
        assert(orbit_http_parse_error_response(arena, 1)->status == 501);
        assert(orbit_http_parse_error_response(arena, 2)->status == 414);
        assert(orbit_http_parse_error_response(arena, 3)->status == 431);
        assert(orbit_http_parse_error_response(arena, 4)->status == 413);
        assert(orbit_http_parse_error_response(arena, 5)->status == 400);
        /* A receive buffer that filled: head open is 431, head closed (body open) is 413. */
        const char* open_head = "GET / HTTP/1.1\r\nX: y";
        const char* open_body = "POST / HTTP/1.1\r\nContent-Length: 20000\r\n\r\nabc";
        assert(orbit_http_buffer_full_response(arena, open_head, strlen(open_head))->status == 431);
        assert(orbit_http_buffer_full_response(arena, open_body, strlen(open_body))->status == 413);
    }

    /* The environment moves the caps; a bad value keeps the default. */
    {
        SET_ENV("ORBIT_HTTP_MAX_BODY", "10");
        SET_ENV("ORBIT_HTTP_MAX_HEADERS", "2");
        SET_ENV("ORBIT_HTTP_MAX_REQUEST_LINE", "banana");
        orbit_http_limits_reload();
        const char* b10 = "POST /u HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789";
        const char* b11 = "POST /u HTTP/1.1\r\nContent-Length: 11\r\n\r\n";
        parse_copy(arena, b10, strlen(b10), &rq, &perr);
        assert(perr == 0 && rq != NULL);
        parse_copy(arena, b11, strlen(b11), &rq, &perr);
        assert(perr == 4);
        const char* h3 = "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n";
        parse_copy(arena, h3, strlen(h3), &rq, &perr);
        assert(perr == 3);
        const char* h2 = "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n";
        parse_copy(arena, h2, strlen(h2), &rq, &perr);
        assert(perr == 0 && rq != NULL);
        SET_ENV("ORBIT_HTTP_MAX_BODY", "");
        SET_ENV("ORBIT_HTTP_MAX_HEADERS", "");
        SET_ENV("ORBIT_HTTP_MAX_REQUEST_LINE", "");
        orbit_http_limits_reload();
        /* Back at 1 MiB: 11 bytes is within it, so the incomplete body just waits. */
        assert(parse_copy(arena, b11, strlen(b11), &rq, &perr) == 0);
        assert(perr == 0);
    }
    orbit_arena_destroy(arena);
}

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

    /* Route patterns: parse a request, match, check captures. */
    {
        const char* raw = "GET /notes/abc-123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        size_t rl = strlen(raw);
        char* mbuf = (char*)malloc(rl + 1);
        assert(mbuf != NULL);
        memcpy(mbuf, raw, rl + 1);
        OrbitRequest* rq = NULL;
        assert(orbit_http_parse_request_ex(arena, mbuf, rl, &rq, NULL) == rl);
        assert(rq != NULL);
        /* :name capture + param_get + empty-name miss. */
        assert(orbit_route_match(arena, rq, "GET", "/notes/:id") == true);
        assert(rq->param_count == 1);
        assert(strcmp(rq->param_names[0], "id") == 0);
        assert(strcmp(rq->param_values[0], "abc-123") == 0);
        assert(strcmp(orbit_http_param_get(arena, rq, "id"), "abc-123") == 0);
        assert(strcmp(orbit_http_param_get(arena, rq, "nope"), "") == 0);
        /* Wrong method / extra segment / missing segment. */
        assert(orbit_route_match(arena, rq, "DELETE", "/notes/:id") == false);
        assert(rq->param_count == 0);
        assert(orbit_route_match(arena, rq, "GET", "/notes/:id/comments") == false);
        assert(orbit_route_match(arena, rq, "GET", "/notes") == false);
        /* {name} form, trailing slash tolerance, literal mismatch. */
        assert(orbit_route_match(arena, rq, "GET", "/notes/{id}") == true);
        assert(strcmp(orbit_http_param_get(arena, rq, "id"), "abc-123") == 0);
        assert(orbit_route_match(arena, rq, "GET", "/notes/:id/") == true);
        assert(orbit_route_match(arena, rq, "GET", "/users/:id") == false);
        /* Static route still exact; wildcard matches one segment. */
        assert(orbit_route_match(arena, rq, "GET", "/notes/abc-123") == true);
        assert(rq->param_count == 0);
        assert(orbit_route_match(arena, rq, "GET", "/notes/*") == true);
        assert(orbit_route_match(arena, rq, "GET", "/*/*") == true);
        assert(orbit_route_match(arena, rq, "GET", "/*") == false);
        /* Multi-capture. */
        assert(orbit_route_match(arena, rq, "GET", "/:a/:b") == true);
        assert(rq->param_count == 2);
        assert(strcmp(orbit_http_param_get(arena, rq, "a"), "notes") == 0);
        assert(strcmp(orbit_http_param_get(arena, rq, "b"), "abc-123") == 0);
        /* Ten captures bind: the limit is 32, so the 9th and 10th bind too. */
        {
            const char* raw10 = "GET /s0/s1/s2/s3/s4/s5/s6/s7/s8/s9 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            size_t rl10 = strlen(raw10);
            char* mbuf10 = (char*)malloc(rl10 + 1);
            assert(mbuf10 != NULL);
            memcpy(mbuf10, raw10, rl10 + 1);
            OrbitRequest* rq10 = NULL;
            assert(orbit_http_parse_request_ex(arena, mbuf10, rl10, &rq10, NULL) == rl10);
            assert(rq10 != NULL);
            assert(orbit_route_match(arena, rq10, "GET", "/:p0/:p1/:p2/:p3/:p4/:p5/:p6/:p7/:p8/:p9") == true);
            assert(rq10->param_count == 10);
            assert(strcmp(orbit_http_param_get(arena, rq10, "p0"), "s0") == 0);
            assert(strcmp(orbit_http_param_get(arena, rq10, "p8"), "s8") == 0);
            assert(strcmp(orbit_http_param_get(arena, rq10, "p9"), "s9") == 0);
            free(mbuf10);
        }
        /* Empty segment never captures; degenerate patterns rejected. */
        assert(orbit_route_match(arena, rq, "GET", "/notes/:") == false);
        assert(orbit_route_match(arena, rq, "GET", "/notes/{}") == false);
        free(mbuf);
    }

    /* Multi-segment capture `:name...`: takes a non-empty rest of path,
     * trailing slashes tolerated, query strings excluded. */
    {
        const char* rawm = "GET /files/a/b/c HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        size_t rlm = strlen(rawm);
        char* mbufm = (char*)malloc(rlm + 1);
        assert(mbufm != NULL);
        memcpy(mbufm, rawm, rlm + 1);
        OrbitRequest* rqm = NULL;
        assert(orbit_http_parse_request_ex(arena, mbufm, rlm, &rqm, NULL) == rlm);
        assert(rqm != NULL);
        assert(orbit_route_match(arena, rqm, "GET", "/files/:p...") == true);
        assert(rqm->param_count == 1);
        assert(strcmp(orbit_http_param_get(arena, rqm, "p"), "a/b/c") == 0);
        /* A single-segment pattern does not span: same request, one segment. */
        assert(orbit_route_match(arena, rqm, "GET", "/files/:p") == false);
        /* A multi pattern never matches an empty rest, a bare name, or a
         * non-final position; the checker rejects the last two statically. */
        assert(orbit_route_match(arena, rqm, "GET", "/files") == false);
        assert(orbit_route_match(arena, rqm, "GET", "/files/:...") == false);
        assert(orbit_route_match(arena, rqm, "GET", "/files/:p.../x") == false);
        assert(orbit_route_match(arena, rqm, "POST", "/files/:p...") == false);
        free(mbufm);
    }

    /* Trailing slashes do not leak into the capture. */
    {
        const char* rawt = "GET /files/a/b/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        size_t rlt = strlen(rawt);
        char* mbuft = (char*)malloc(rlt + 1);
        assert(mbuft != NULL);
        memcpy(mbuft, rawt, rlt + 1);
        OrbitRequest* rqt = NULL;
        assert(orbit_http_parse_request_ex(arena, mbuft, rlt, &rqt, NULL) == rlt);
        assert(rqt != NULL);
        assert(orbit_route_match(arena, rqt, "GET", "/files/:p...") == true);
        assert(strcmp(orbit_http_param_get(arena, rqt, "p"), "a/b") == 0);
        free(mbuft);
    }

    /* Header block copy for auth/header builtins: present with content,
     * absent (NULL) only when the request carries no header lines. */
    {
        const char* raw = "GET /v1/notes/secured HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok_admin\r\n\r\n";
        size_t rl = strlen(raw);
        char* hbuf = (char*)malloc(rl + 1);
        assert(hbuf != NULL);
        memcpy(hbuf, raw, rl + 1);
        OrbitRequest* rh = NULL;
        assert(orbit_http_parse_request_ex(arena, hbuf, rl, &rh, NULL) == rl);
        assert(rh != NULL);
        assert(rh->headers != NULL);
        assert(strstr(rh->headers, "Authorization: Bearer tok_admin") != NULL);
        assert(rh->headers_len == strlen(rh->headers));
        free(hbuf);
    }

    orbit_arena_destroy(arena);
    free(buf);

    test_http_limits();
    printf("http limits tests: PASSED\n");
    printf("http parse pipelined tests: PASSED\n");
    printf("http route match tests: PASSED\n");
    printf("http header block tests: PASSED\n");
    return 0;
}