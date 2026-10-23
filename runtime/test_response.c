/* Response convenience wrappers: status, content type and body.
 *
 * orbit_response_json/error/html are one-line wrappers over
 * orbit_response_create; the only contract is the Content-Type each sets.
 * A wrapper that set the wrong type would serve bytes the client refuses to
 * render, so each type is asserted here, not trusted from the name.
 *
 * The wire checks at the bottom stage header blocks bigger than the fast-path
 * buffer and compare the bytes that arrive against the documented shape: a
 * header that did not fit its buffer must never be sent at the length it
 * would have had, because the bytes past the buffer are whatever the stack
 * held.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "runtime.h"

/* One response, sent over a loopback pair, byte-compared on the wire.
 * @p eh_target is the minimum size of the staged extra-headers block:
 * for a text/plain 200 with a short body, >= 376 pushes the header past
 * the 512-byte fast-path buffer and into the fallback. The pair is
 * single-threaded: connect() completes against the backlog, then accept(). */
static int check_wire(OrbitArena* arena, const char* label, size_t eh_target) {
    const char* body = "hello";
    char blob[16384];
    char expect[16384];
    char wire[16384];
    size_t staged = 0;
    size_t expect_len;
    size_t got = 0;
    size_t i;
    size_t need;
    int want;
    int n;
    int idx;
    OrbitResponse* r;
    orbit_socket_t ls = ORBIT_INVALID_SOCKET;
    orbit_socket_t c = ORBIT_INVALID_SOCKET;
    orbit_socket_t s = ORBIT_INVALID_SOCKET;
    struct sockaddr_in addr;

    /* Whole "X-Fill-NNN: ..." lines until the staged block covers the
     * target: the trigger is extra_headers_len, so the test counts staged
     * bytes, not lines. 78 is the fixed line width (12 + 64 + 2). */
    for (idx = 0; staged < eh_target; idx++) {
        need = sizeof(blob) - staged;
        n = snprintf(blob + staged, need,
                     "X-Fill-%03d: %s\r\n", idx,
                     "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert(n > 0 && (size_t)n < need);
        staged += (size_t)n;
    }

    r = orbit_response_create(arena, 200, "text/plain", body);
    assert(r != NULL);
    orbit_response_add_headers(arena, r, blob);
    if (r->extra_headers_len != staged || !r->extra_headers ||
        strcmp(r->extra_headers, blob) != 0) {
        printf("FAILED %s staged block did not round-trip\n", label);
        return 1;
    }

    /* The documented shape, spelled out independently of the function
     * under test; every send path must be byte-identical to it. */
    want = snprintf(expect, sizeof(expect),
        "HTTP/1.1 %d %s\r\n"
        "Server: Orbit\r\n"
        "Content-Type: %s\r\n"
        "%s"
        "Connection: keep-alive\r\n"
        "Keep-Alive: timeout=30, max=1000\r\n"
        "Content-Length: %d\r\n"
        "\r\n"
        "%s",
        r->status, orbit_reason_phrase(r->status), r->content_type,
        blob, (int)r->body_len, body);
    assert(want > 0 && (size_t)want < sizeof(expect));
    expect_len = (size_t)want;

    ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls == ORBIT_INVALID_SOCKET) {
        printf("FAILED %s listen socket\n", label);
        return 1;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(ls, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        printf("FAILED %s bind loopback\n", label);
        orbit_socket_close(ls);
        return 1;
    }
    {
        struct sockaddr_in bound;
        int blen = (int)sizeof(bound);
        if (getsockname(ls, (struct sockaddr*)&bound, &blen) != 0) {
            printf("FAILED %s getsockname\n", label);
            orbit_socket_close(ls);
            return 1;
        }
        addr.sin_port = bound.sin_port;
    }
    if (listen(ls, 1) != 0) {
        printf("FAILED %s listen\n", label);
        orbit_socket_close(ls);
        return 1;
    }

    c = socket(AF_INET, SOCK_STREAM, 0);
    if (c == ORBIT_INVALID_SOCKET) {
        printf("FAILED %s client socket\n", label);
        orbit_socket_close(ls);
        return 1;
    }
    orbit_set_recv_timeout(c, 5000);
    if (connect(c, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        printf("FAILED %s connect\n", label);
        orbit_socket_close(c);
        orbit_socket_close(ls);
        return 1;
    }
    s = accept(ls, NULL, NULL);
    if (s == ORBIT_INVALID_SOCKET) {
        printf("FAILED %s accept\n", label);
        orbit_socket_close(c);
        orbit_socket_close(ls);
        return 1;
    }

    orbit_send_response(s, r);

    /* Read exactly the expected length: the server keeps the connection
     * open (keep-alive), so a read to EOF would hang until the timeout. */
    while (got < expect_len) {
        n = recv(c, wire + got, (int)(sizeof(wire) - got), 0);
        if (n <= 0) break;
        got += (size_t)n;
    }
    if (got != expect_len) {
        printf("FAILED %s wire length: got %d want %d\n",
               label, (int)got, (int)expect_len);
        orbit_socket_close(s);
        orbit_socket_close(c);
        orbit_socket_close(ls);
        return 1;
    }
    for (i = 0; i < expect_len; i++) {
        if (wire[i] != expect[i]) {
            printf("FAILED %s wire byte %d: got 0x%02x want 0x%02x\n",
                   label, (int)i, (unsigned char)wire[i], (unsigned char)expect[i]);
            orbit_socket_close(s);
            orbit_socket_close(c);
            orbit_socket_close(ls);
            return 1;
        }
    }

    orbit_socket_close(s);
    orbit_socket_close(c);
    orbit_socket_close(ls);
    return 0;
}

int main(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    OrbitResponse* html = orbit_response_html(arena, 200, "<h1>hi</h1>");
    assert(html != NULL);
    assert(html->status == 200);
    assert(strcmp(html->content_type, "text/html") == 0);
    assert(strcmp(html->body, "<h1>hi</h1>") == 0);

    OrbitResponse* json = orbit_response_json(arena, 201, "{\"a\":1}");
    assert(json != NULL);
    assert(json->status == 201);
    assert(strcmp(json->content_type, "application/json") == 0);

    OrbitResponse* err = orbit_response_error(arena, 404, "nope");
    assert(err != NULL);
    assert(err->status == 404);
    assert(strcmp(err->content_type, "text/plain") == 0);

    OrbitResponse* empty = orbit_response_html(arena, 200, NULL);
    assert(empty != NULL);
    assert(empty->body_len == 0);

    /* Reason phrases: the assigned codes a server plausibly emits, plus
     * the empty phrase for unassigned ones (a 307 used to go out as
     * "307 OK"). Lengths are strlen-checked here so no hand count can
     * drift: the send path measures with strlen too. */    {
        static const struct { int code; const char* want; } cases[] = {
            {200, "OK"},
            {201, "Created"},
            {204, "No Content"},
            {301, "Moved Permanently"},
            {302, "Found"},
            {303, "See Other"},
            {304, "Not Modified"},
            {307, "Temporary Redirect"},
            {308, "Permanent Redirect"},
            {400, "Bad Request"},
            {404, "Not Found"},
            {410, "Gone"},
            {418, "I'm a teapot"},
            {429, "Too Many Requests"},
            {451, "Unavailable For Legal Reasons"},
            {500, "Internal Server Error"},
            {503, "Service Unavailable"},
            {599, ""},
            {99, ""},
        };
        size_t i;
        for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
            const char* got = orbit_reason_phrase(cases[i].code);
            if (strcmp(got, cases[i].want) != 0) {
                printf("FAILED phrase %d: got %s want %s\n",
                       cases[i].code, got, cases[i].want);
                return 1;
            }
        }
    }

    /* Staged header lines flush onto the response; a line smuggling CRLF
     * in the name or value is refused whole at the choke point
     * (header_line), so the flush below only ever sees clean lines --
     * the evil case asserts the refusal, not the flush. */
    {
        OrbitResponse* r = orbit_response_create(arena, 302, "text/plain", "moved");
        assert(r != NULL);
        assert(strcmp(orbit_response_header_line(arena, "X-A", "b"), "X-A: b\r\n") == 0);
        assert(strcmp(orbit_response_header_line(arena, "", "b"), "") == 0);
        assert(strcmp(orbit_response_header_line(arena, "X:Y", "b"), "") == 0);
        assert(strcmp(orbit_response_header_line(arena, "X-A", "a\r\nB: 1"), "") == 0);
        orbit_response_add_headers(arena, r, "Location: /new\r\nX-A: b\r\n");
        assert(r->extra_headers_len == strlen("Location: /new\r\nX-A: b\r\n"));
        assert(strcmp(r->extra_headers, "Location: /new\r\nX-A: b\r\n") == 0);
    }

    /* Optional whitespace before the colon is trimmed from the source
     * bytes; reading the not-yet-written copy trims nothing or garbage. */
    {
        OrbitResponse* r = orbit_response_create(arena, 200, "text/plain", "ok");
        assert(r != NULL);
        orbit_response_add_headers(arena, r, "X-Space : 1\r\n");
        assert(strcmp(r->extra_headers, "X-Space: 1\r\n") == 0);
    }

    /* The wire: a staged block under 128 B keeps the fast path, 600+ B
     * forces the fallback, and 9000+ B forces the direct send (header +
     * body past 8192). All three must arrive byte-exact. */
    orbit_http_init();
    if (check_wire(arena, "small", 78) != 0) return 1;
    if (check_wire(arena, "mid", 600) != 0) return 1;
    if (check_wire(arena, "large", 9000) != 0) return 1;

    printf("PASS test_response\n");
    return 0;
}
