/* Interface of runtime/http.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_HTTP_H
#define ORBIT_RT_HTTP_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "socket_compat.h"
#ifndef _WIN32
#include <netdb.h>
#include <sys/time.h>
#include <sys/select.h>
#endif
#include "arena.h"
#include "types.h"

#if defined(_WIN32)
#define ORBIT_STRNCASECMP _strnicmp
#else
#define ORBIT_STRNCASECMP strncasecmp
#endif

#if defined(_WIN32) && defined(_MSC_VER)
#pragma comment(lib, "ws2_32.lib")
#endif

/* â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
 * Orbit HTTP â€” Arena-backed request/response handling.
 *
 * All buffers are allocated from the request Arena, not stack-fixed.
 * This means request size is limited only by Arena capacity, not
 * by hardcoded buffer constants.
 * â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

/* Path-parameter slots filled by orbit_route_match (route_runtime patterns
 * such as "/notes/:id"). The same fields exist on the fallback declaration
 * in builtins.c; keep both in sync. */
#define ORBIT_MAX_PATH_PARAMS 32
typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
    char* param_names[ORBIT_MAX_PATH_PARAMS];
    char* param_values[ORBIT_MAX_PATH_PARAMS];
    int param_count;
} OrbitRequest;

/** @brief Parse a raw HTTP byte stream into an arena-allocated OrbitRequest; returns bytes consumed, or 0 if the request is incomplete. */
size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req);
size_t orbit_http_parse_request_ex(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req, int* out_parse_error);
/** @brief Match req path against a route pattern (":name", "{name}", ":name..." and "*" segments). Fills path params; false leaves none. */
bool orbit_route_match(OrbitArena* arena, OrbitRequest* req, const char* method, const char* pattern);


typedef struct {
    int    status;
    char*  body;
    size_t body_len;
    char*  content_type;
    char*  extra_headers;      /* optional raw "Name: value\r\n" block (Retry-After…) */
    size_t extra_headers_len;
} OrbitResponse;

// Forward declaration for Pulsar support
#include "pulse.h"

void orbit_http_limits_reload(void);
void orbit_http_init(void);
void orbit_http_cleanup(void);

/* ── Request limits ───────────────────────────────────────────────────
 *
 * Every limit is checked on the raw bytes, before the parser allocates
 * anything from the arena, so a hostile request costs the server no more
 * than the bytes it already read. Defaults follow nginx and Go:
 *
 *   ORBIT_HTTP_MAX_REQUEST_LINE   8192     request line, in bytes  -> 414
 *   ORBIT_HTTP_MAX_HEADER_BYTES   65536    all header lines        -> 431
 *   ORBIT_HTTP_MAX_HEADERS        100      header lines            -> 431
 *   ORBIT_HTTP_MAX_BODY           1048576  Content-Length          -> 413
 *
 * Each variable is a decimal integer in 1..2147483648. Anything else is
 * ignored with one line on stderr and the default stays. The limits are read
 * once, by orbit_http_init (or by the first parse). The server's per-connection
 * receive buffer is 16 KiB, so on a live socket it bounds a request before any
 * of these larger values can. */
typedef struct {
    size_t max_request_line;
    size_t max_header_bytes;
    size_t max_headers;
    size_t max_body;
    int    loaded;
} OrbitHttpLimits;

#define ORBIT_HTTP_PERR_CHUNKED 1 /* 501 */
#define ORBIT_HTTP_PERR_LINE    2 /* 414 */
#define ORBIT_HTTP_PERR_HEADERS 3 /* 431 */
#define ORBIT_HTTP_PERR_BODY    4 /* 413 */
#define ORBIT_HTTP_PERR_LENGTH  5 /* 400: malformed or conflicting Content-Length */
void orbit_http_limits_reload(void);

OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body);
OrbitResponse* orbit_http_parse_error_response(OrbitArena* arena, int code);
OrbitResponse* orbit_http_buffer_full_response(OrbitArena* arena, const char* buf, size_t len);
size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req);
size_t orbit_http_parse_request_ex(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req, int* out_parse_error);
OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body);
void orbit_response_add_header(OrbitArena* arena, OrbitResponse* resp, const char* name, const char* value);
orbit_string orbit_response_header_line(OrbitArena* arena, const char* name, const char* value);
void orbit_response_add_headers(OrbitArena* arena, OrbitResponse* resp, const char* block);
OrbitResponse* orbit_response_json(OrbitArena* arena, int status, const char* json);
OrbitResponse* orbit_response_html(OrbitArena* arena, int status, const char* html);
OrbitResponse* orbit_response_error(OrbitArena* arena, int status, const char* message);
OrbitResponse* orbit_response_or_500(OrbitArena* arena, OrbitResponse* resp);
const char* orbit_reason_phrase(int status);
void orbit_send_response(orbit_socket_t client, OrbitResponse* resp);
bool orbit_route_match(OrbitArena* arena, OrbitRequest* req, const char* method, const char* pattern);
orbit_string orbit_http_header_get(OrbitArena* arena, OrbitRequest* req, orbit_string name);

#if !defined(ORBIT_CUSTOM_ROUTER) && !defined(ORBIT_LIB_NO_ROUTER)
int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed);

#endif

/* ── Minimal blocking HTTP/1.1 client ─────────────────────────────────
 *
 * GET http://host[:port][/path] and answer ok(body). What it is not, on
 * purpose: no TLS (https is err, stated, never attempted -- there is no
 * TLS stack in this tree to attempt it with), no redirect following (a
 * 3xx is a response like any other), no auth, no proxy, no HEAD/POST.
 * Any well-formed reply is ok(body); only transport and framing
 * failures are err, and the reply status itself is not surfaced.
 *
 * Timeouts: 10 s to connect (select, both platforms -- a blocking
 * connect would hang for OS minutes on a blackhole), 10 s per recv
 * (SO_RCVTIMEO). Bodies arrive by Content-Length, by chunked framing,
 * or by close-delimited read, in that precedence; a short
 * Content-Length body is err, never partial. Bounded by the arena like
 * every other answer here: a body bigger than the arena is OOM err.
 * Bodies are text -- an embedded NUL truncates at the first byte, the
 * orbit_string contract everywhere else too. */

#define ORBIT_HTTP_CLIENT_TIMEOUT_MS 10000

/* Growable arena buffer: the arena has no realloc, so growth copies
 * forward and abandons the old block (runtime/file.c does the same). */
typedef struct {
    char* data;
    size_t len;
    size_t cap;
    OrbitArena* arena;
    int failed;
} HttpBuf;
ORBIT_UNUSED OrbitResult orbit_http_client_fetch(OrbitArena* arena, orbit_string url);

/* Loopback check for the ledger and Pulse pages. Lives with the sockets so a
 * program without a network never links getpeername. */
int orbit_ledger_is_loopback(orbit_socket_t s);

#endif
