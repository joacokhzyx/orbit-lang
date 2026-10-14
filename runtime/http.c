/**
 * @file  http.c
 * @brief Arena-backed HTTP request parsing and response construction for Orbit.
 *
 * Parses raw HTTP/1.1 byte streams into OrbitRequest structs allocated entirely
 * within the request arena (no fixed-size stack buffers).  Response builders
 * create OrbitResponse objects in the same arena; orbit_send_response() writes
 * header + body to the client socket in a single call where possible.
 */
#ifndef ORBIT_HTTP_H
#define ORBIT_HTTP_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "socket_compat.h"
#ifndef _WIN32
#include <netdb.h>
#include <sys/time.h>
#include <sys/select.h>
#endif
#include "arena.c"
#include "types.c"

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

#ifndef ORBIT_HTTP_H
#define ORBIT_HTTP_H
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
#endif

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
#include "pulse.c"

/** @brief Initialise the HTTP layer (starts Winsock on Windows; no-op on POSIX). */
void orbit_http_init(void) {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    /* The energy sampler lives exactly as long as the server. The guard
     * keeps translation units that include http.c without energy.c -- the
     * C unit tests, for instance -- compiling unchanged. */
#ifdef ORBIT_ENERGY_C
    orbit_energy_start();
#endif
}

/** @brief Shut down the HTTP layer (stops Winsock on Windows; no-op on POSIX). */
void orbit_http_cleanup(void) {
#ifdef ORBIT_ENERGY_C
    orbit_energy_stop();
#endif
#ifdef _WIN32
    WSACleanup();
#endif
}

/* â”€â”€ Parse raw HTTP into Arena-allocated OrbitRequest â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req) {
    return orbit_http_parse_request_ex(arena, raw, raw_len, out_req, NULL);
}

size_t orbit_http_parse_request_ex(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req, int* out_parse_error) {
    if (out_req) *out_req = NULL;
    
    // Ensure we have a complete HTTP request header
    const char* headers_end = strstr(raw, "\r\n\r\n");
    if (!headers_end) return 0;

    const char* body_start = headers_end + 4;

    if (out_parse_error) *out_parse_error = 0;
    /* Single-pass header scan: the Transfer-Encoding: chunked reject (R3.3,
     * request-smuggling vector) and the Content-Length resolution share one
     * line walk. First-byte dispatch selects the only two prefixes of
     * interest; all other lines cost a single memchr. */
    size_t content_length = 0;
    {
        const char* hdr_scan = raw;
        long long cl_value = -1;
        int cl_seen = 0;
        int te_chunked = 0;
        while (hdr_scan < body_start) {
            const char* line_end = memchr(hdr_scan, '\n', (size_t)(body_start - hdr_scan));
            if (!line_end) break;
            size_t line_len = (size_t)(line_end - hdr_scan);
            if (line_len > 15) {
                char c0 = hdr_scan[0];
                if ((c0 == 't' || c0 == 'T') && line_len > 19 &&
                    ORBIT_STRNCASECMP(hdr_scan, "transfer-encoding:", 18) == 0) {
                    const char* v = hdr_scan + 18;
                    while (v < line_end && (*v == ' ' || *v == '\t')) v++;
                    if ((size_t)(line_end - v) >= 7 && ORBIT_STRNCASECMP(v, "chunked", 7) == 0) {
                        te_chunked = 1;
                    }
                } else if ((c0 == 'c' || c0 == 'C') &&
                           ORBIT_STRNCASECMP(hdr_scan, "content-length:", 15) == 0) {
                    /* Manual integer parse with strtoll-compatible results:
                     * same leading-whitespace set, optional sign, digit run,
                     * no-digits yields 0, saturation at LLONG_MAX. */
                    const char* p = hdr_scan + 15;
                    while (p < line_end && (*p == ' ' || *p == '\t' || *p == '\r' ||
                                            *p == '\v' || *p == '\f')) p++;
                    int neg = 0;
                    if (p < line_end && (*p == '-' || *p == '+')) {
                        neg = (*p == '-');
                        p++;
                    }
                    unsigned long long acc = 0;
                    int digits = 0;
                    while (p < line_end && *p >= '0' && *p <= '9') {
                        unsigned d = (unsigned)(*p - '0');
                        if (acc > ((unsigned long long)0x7FFFFFFFFFFFFFFFULL - d) / 10ULL) {
                            acc = (unsigned long long)0x7FFFFFFFFFFFFFFFULL;
                            while (p < line_end && *p >= '0' && *p <= '9') p++;
                            digits++;
                            break;
                        }
                        acc = acc * 10ULL + d;
                        p++;
                        digits++;
                    }
                    long long v = (digits == 0) ? 0LL
                        : (neg ? -(long long)acc : (long long)acc);
                    if (!cl_seen) {
                        cl_value = v;
                        cl_seen = 1;
                    } else if (v != cl_value) {
                        cl_seen = -1; /* conflicting lengths: ambiguous */
                    }
                }
            }
            hdr_scan = line_end + 1;
        }
        if (te_chunked) {
            if (out_parse_error) *out_parse_error = 1;
            if (out_req) *out_req = NULL;
            return raw_len; /* consume buffer; caller responds 501 and closes */
        }
        if (cl_seen == 1 && cl_value > 0) {
            content_length = (size_t)cl_value;
        }
    }

    // If we don't have the full body yet, return 0 to wait for more data
    if (raw_len < (size_t)(body_start - raw) + content_length) {
        if (out_req) *out_req = NULL;
        return 0; // Incomplete body
    }

    OrbitRequest* req = (OrbitRequest*)orbit_alloc(arena, sizeof(OrbitRequest));
    if (!req) return 0;
    memset(req, 0, sizeof(OrbitRequest));

    /* Header block copy for req->headers (auth/header builtins). Arena copy:
     * the raw buffer is mutated in place below (method/path NULs) and reused
     * across pipelined requests, so a slice would alias garbage. Stays NULL
     * when the request carries no header lines. */
    {
        const char* line1 = memchr(raw, '\n', raw_len);
        if (line1 && line1 + 1 < headers_end) {
            size_t hlen = (size_t)(headers_end - (line1 + 1));
            char* hcopy = (char*)orbit_alloc(arena, hlen + 1);
            if (hcopy) {
                memcpy(hcopy, line1 + 1, hlen);
                hcopy[hlen] = '\0';
                req->headers = hcopy;
                req->headers_len = hlen;
            }
        }
    }

    // Zero-Copy Slice Parsing: modify mutable byte stream in-place when safe
    char* mutable_raw = (char*)raw;

    /* Method (until first space) */
    const char* space = memchr(raw, ' ', raw_len);
    if (!space) return 0;

    size_t method_len = (size_t)(space - raw);
    req->method = mutable_raw;
    mutable_raw[method_len] = '\0';

    /* Path (between first and second space) */
    const char* path_start = space + 1;
    const char* path_end = memchr(path_start, ' ', raw_len - (size_t)(path_start - raw));
    if (!path_end) path_end = path_start;

    size_t path_end_off = (size_t)(path_end - raw);

    /* Split path from query string at '?' */
    const char* query = memchr(path_start, '?', (size_t)(path_end - path_start));
    if (query) {
        size_t query_off = (size_t)(query - raw);
        req->path = (char*)path_start;
        mutable_raw[query_off] = '\0';
        req->query = (char*)(query + 1);
        mutable_raw[path_end_off] = '\0';
    } else {
        req->path = (char*)path_start;
        mutable_raw[path_end_off] = '\0';
        req->query = NULL;
    }

    /* Body (after \r\n\r\n) */
    req->body_len = content_length;
    if (req->body_len > 0) {
        // Copy the body into the arena with a null terminator instead of
        // writing the terminator into the shared read buffer. With pipelined
        // requests that byte is the first byte of the next request, which the
        // previous code clobbered with '\0', corrupting its method/path and
        // making the router return 404 for every request after the first.
        char* body_copy = (char*)orbit_alloc(arena, req->body_len + 1);
        if (body_copy) {
            memcpy(body_copy, body_start, req->body_len);
            body_copy[req->body_len] = '\0';
            req->body = body_copy;
        } else {
            req->body = NULL;
            req->body_len = 0;
        }
    } else {
        req->body = NULL;
    }
    size_t consumed = (size_t)(body_start - raw) + content_length;

    if (out_req) *out_req = req;
    return consumed;
}

/* â”€â”€ Response builders â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

/** @brief Create an arena-allocated OrbitResponse with the given @p status, @p content_type, and @p body. */
OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body) {
    OrbitResponse* resp = (OrbitResponse*)orbit_alloc(arena, sizeof(OrbitResponse));
    if (!resp) return NULL;

    resp->status = status;
    resp->content_type = (char*)content_type;
    resp->body = (char*)body;
    resp->body_len = body ? strlen(body) : 0;
    resp->extra_headers = NULL;
    resp->extra_headers_len = 0;
    return resp;
}

/** @brief Append one raw header line ("Name: value\r\n") to @p resp's header block. */
void orbit_response_add_header(OrbitArena* arena, OrbitResponse* resp, const char* name, const char* value) {
    if (!arena || !resp || !name || !value) return;
    size_t name_len = strlen(name);
    size_t value_len = strlen(value);
    size_t line_len = name_len + 2 + value_len + 2; /* ": " + "\r\n" */
    char* line = (char*)orbit_alloc(arena, line_len + 1);
    if (!line) return;
    memcpy(line, name, name_len);
    memcpy(line + name_len, ": ", 2);
    memcpy(line + name_len + 2, value, value_len);
    memcpy(line + name_len + 2 + value_len, "\r\n", 2);
    line[line_len] = '\0';
    if (resp->extra_headers && resp->extra_headers_len > 0) {
        size_t old = resp->extra_headers_len;
        char* joined = (char*)orbit_alloc(arena, old + line_len + 1);
        if (!joined) return;
        memcpy(joined, resp->extra_headers, old);
        memcpy(joined + old, line, line_len + 1);
        resp->extra_headers = joined;
        resp->extra_headers_len = old + line_len;
    } else {
        resp->extra_headers = line;
        resp->extra_headers_len = line_len;
    }
}

/** @brief Convenience wrapper: create a JSON response with Content-Type application/json. */
OrbitResponse* orbit_response_json(OrbitArena* arena, int status, const char* json) {
    return orbit_response_create(arena, status, "application/json", json);
}

/** @brief Convenience wrapper: create an HTML response with Content-Type text/html. */
OrbitResponse* orbit_response_html(OrbitArena* arena, int status, const char* html) {
    return orbit_response_create(arena, status, "text/html", html);
}


/** @brief Convenience wrapper: create an error response with Content-Type text/plain. */
OrbitResponse* orbit_response_error(OrbitArena* arena, int status, const char* message) {
    return orbit_response_create(arena, status, "text/plain", message);
}

/* â”€â”€ Send response to socket â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

/** @brief Append the decimal rendering of @p v (exact %d semantics, sign-safe) and return the new end. */
static char* orbit_append_int(char* p, int v) {
    uint32_t mag = (v < 0) ? (uint32_t)(-(v + 1)) + 1u : (uint32_t)v;
    if (v < 0) *p++ = '-';
    char tmp[10];
    int n = 0;
    if (mag == 0) {
        *p++ = '0';
        return p;
    }
    while (mag > 0) {
        tmp[n++] = (char)('0' + mag % 10u);
        mag /= 10u;
    }
    while (n > 0) *p++ = tmp[--n];
    return p;
}

/** @brief Write @p resp (header + body) to @p client in a single fast-path send() syscall. */
void orbit_send_response(orbit_socket_t client, OrbitResponse* resp) {
    if (!resp) return;

    const char* body = resp->body ? resp->body : "";
    size_t body_len  = resp->body_len;
    const char* ct   = resp->content_type ? resp->content_type : "text/plain";

    #ifdef ORBIT_WITH_NET
    extern bool orbit_kynx_lease_check_limits(size_t additional_response_bytes);
    if (!orbit_kynx_lease_check_limits(body_len)) {
        body = "Kynx: Response Limit Exceeded\n";
        body_len = strlen(body);
        resp->status = 500;
        ct = "text/plain";
    }
    #endif

    /* Resolve HTTP reason phrase for the status code */
    const char* reason;
    size_t reason_len;
    switch (resp->status) {
        case 200: reason = "OK"; reason_len = 2; break;
        case 201: reason = "Created"; reason_len = 7; break;
        case 204: reason = "No Content"; reason_len = 10; break;
        case 301: reason = "Moved Permanently"; reason_len = 17; break;
        case 302: reason = "Found"; reason_len = 5; break;
        case 304: reason = "Not Modified"; reason_len = 12; break;
        case 400: reason = "Bad Request"; reason_len = 11; break;
        case 401: reason = "Unauthorized"; reason_len = 12; break;
        case 403: reason = "Forbidden"; reason_len = 9; break;
        case 404: reason = "Not Found"; reason_len = 9; break;
        case 405: reason = "Method Not Allowed"; reason_len = 18; break;
        case 408: reason = "Request Timeout"; reason_len = 15; break;
        case 409: reason = "Conflict"; reason_len = 8; break;
        case 413: reason = "Content Too Large"; reason_len = 17; break;
        case 422: reason = "Unprocessable Entity"; reason_len = 20; break;
        case 429: reason = "Too Many Requests"; reason_len = 17; break;
        case 431: reason = "Request Header Fields Too Large"; reason_len = 31; break;
        case 500: reason = "Internal Server Error"; reason_len = 21; break;
        case 501: reason = "Not Implemented"; reason_len = 15; break;
        case 502: reason = "Bad Gateway"; reason_len = 11; break;
        case 503: reason = "Service Unavailable"; reason_len = 19; break;
        default:  reason = "OK"; reason_len = 2; break;
    }

    /* Manual header build: byte-identical to the previous snprintf shape
     * (same status/reason/content-type/length bytes, same (int) length
     * truncation), without varargs and format-string parsing per request.
     * Pathological inputs fall back to the bounded snprintf shape. */
    char header[512];
    size_t ct_len = strlen(ct);
    size_t eh_len = resp->extra_headers ? resp->extra_headers_len : 0;
    int header_len;
    if (reason_len <= 32 && ct_len <= 128 && eh_len <= 128) {
        static const char h1[] = "HTTP/1.1 ";
        static const char h2[] = "\r\nServer: Orbit\r\nContent-Type: ";
        static const char h3[] = "\r\nConnection: keep-alive\r\nKeep-Alive: timeout=30, max=1000\r\nContent-Length: ";
        static const char h4[] = "\r\n\r\n";
        char* h = header;
        memcpy(h, h1, sizeof(h1) - 1); h += sizeof(h1) - 1;
        h = orbit_append_int(h, resp->status);
        *h++ = ' ';
        memcpy(h, reason, reason_len); h += reason_len;
        memcpy(h, h2, sizeof(h2) - 1); h += sizeof(h2) - 1;
        memcpy(h, ct, ct_len); h += ct_len;
        if (eh_len > 0) {
            /* With extra headers the Content-Type line needs its own
             * terminator here, and h3's leading CRLF must be skipped:
             * it only terminates Content-Type in the no-headers case.
             * Both shapes stay byte-identical to the snprintf fallback. */
            static const char h3e[] = "Connection: keep-alive\r\nKeep-Alive: timeout=30, max=1000\r\nContent-Length: ";
            *h++ = '\r'; *h++ = '\n';
            memcpy(h, resp->extra_headers, eh_len); h += eh_len;
            memcpy(h, h3e, sizeof(h3e) - 1); h += sizeof(h3e) - 1;
        } else {
            memcpy(h, h3, sizeof(h3) - 1); h += sizeof(h3) - 1;
        }
        h = orbit_append_int(h, (int)body_len);
        memcpy(h, h4, sizeof(h4) - 1); h += sizeof(h4) - 1;
        header_len = (int)(h - header);
    } else {
        header_len = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\n"
            "Server: Orbit\r\n"
            "Content-Type: %s\r\n"
            "%s"
            "Connection: keep-alive\r\n"
            "Keep-Alive: timeout=30, max=1000\r\n"
            "Content-Length: %d\r\n"
            "\r\n",
            resp->status, reason, ct,
            resp->extra_headers ? resp->extra_headers : "",
            (int)body_len);
    }

    if (header_len > 0) {
        size_t total_len = (size_t)header_len + body_len;
        if (total_len < 8192) {
            char combined[8192];
            memcpy(combined, header, (size_t)header_len);
            if (body_len > 0) {
                memcpy(combined + header_len, body, body_len);
            }
            send(client, combined, (int)total_len, 0);
        } else {
            send(client, header, header_len, 0);
            if (body_len > 0) {
                send(client, body, (int)body_len, 0);
            }
        }
    }
}

/* â”€â”€ Main Dispatch Hook â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

/** @brief Match req->path against a route pattern and capture path params.
 *
 * Segments compare literally except `:name` / `{name}` (capture a non-empty
 * segment under name), `:name...` (capture the non-empty REST of the path
 * under name; only meaningful as the final pattern segment), and `*` (match
 * one non-empty segment, no capture).
 * Empty segments are skipped on both sides, so a trailing slash is
 * tolerated. Values are NOT percent-decoded. On success the captures land
 * in req->param_names/values (arena copies, at most ORBIT_MAX_PATH_PARAMS,
 * extras dropped); on any failure param_count is 0 so a previous attempt
 * in a matcher chain can never leak into the next one.
 */
bool orbit_route_match(OrbitArena* arena, OrbitRequest* req, const char* method, const char* pattern) {
    const char *pp, *qp;
    int n = 0;
    if (req) req->param_count = 0;
    if (!req || !req->path || !req->method || !method || !pattern) return false;
    if (strcmp(req->method, method) != 0) return false;
    {
        OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
        pp = pattern;
        qp = req->path;
        for (;;) {
            const char *pe, *qe;
            size_t plen, qlen;
            while (*pp == '/') pp++;
            while (*qp == '/') qp++;
            /* Reject embedded query strings defensively: the parser splits
             * them into req->query, but a hand-built request may not. */
            if (*qp == '?' || *qp == '#') qp = "";
            if (*pp == '\0' && *qp == '\0') {
                req->param_count = n;
                return true;
            }
            if (*pp == '\0' || *qp == '\0') return false;
            pe = pp;
            while (*pe && *pe != '/') pe++;
            qe = qp;
            while (*qe && *qe != '/' && *qe != '?' && *qe != '#') qe++;
            plen = (size_t)(pe - pp);
            qlen = (size_t)(qe - qp);
            if (qlen == 0) return false;
            if (pp[0] == ':' && plen > 4 && memcmp(pe - 3, "...", 3) == 0) {
                /* `:name...` captures the rest of the path and is only
                 * meaningful as the final pattern segment; the checker
                 * rejects anything after it, so more pattern here means a
                 * hand-built matcher call: fail rather than mis-capture. */
                if (*pe != '\0') return false;
                const char* qend = qp;
                while (*qend && *qend != '?' && *qend != '#') qend++;
                while (qend > qp && qend[-1] == '/') qend--;
                size_t vlen = (size_t)(qend - qp);
                if (vlen == 0) return false;
                if (n < ORBIT_MAX_PATH_PARAMS) {
                    char* nm = (char*)orbit_alloc(ar, plen - 3);
                    char* vv = (char*)orbit_alloc(ar, vlen + 1);
                    if (!nm || !vv) return false;
                    memcpy(nm, pp + 1, plen - 4);
                    nm[plen - 4] = '\0';
                    memcpy(vv, qp, vlen);
                    vv[vlen] = '\0';
                    req->param_names[n] = nm;
                    req->param_values[n] = vv;
                }
                n++;
                req->param_count = n;
                return true;
            }
            if (pp[0] == ':') {
                if (plen < 2) return false;
                if (n < ORBIT_MAX_PATH_PARAMS) {
                    char* nm = (char*)orbit_alloc(ar, plen);
                    char* vv = (char*)orbit_alloc(ar, qlen + 1);
                    if (!nm || !vv) return false;
                    memcpy(nm, pp + 1, plen - 1);
                    nm[plen - 1] = '\0';
                    memcpy(vv, qp, qlen);
                    vv[qlen] = '\0';
                    req->param_names[n] = nm;
                    req->param_values[n] = vv;
                }
                n++;
            } else if (plen >= 2 && pp[0] == '{' && pe[-1] == '}') {
                if (plen == 2) return false;
                if (n < ORBIT_MAX_PATH_PARAMS) {
                    char* nm = (char*)orbit_alloc(ar, plen - 1);
                    char* vv = (char*)orbit_alloc(ar, qlen + 1);
                    if (!nm || !vv) return false;
                    memcpy(nm, pp + 1, plen - 2);
                    nm[plen - 2] = '\0';
                    memcpy(vv, qp, qlen);
                    vv[qlen] = '\0';
                    req->param_names[n] = nm;
                    req->param_values[n] = vv;
                }
                n++;
            } else if (plen == 1 && pp[0] == '*') {
                /* single-segment wildcard, not captured */
            } else {
                if (plen != qlen || memcmp(pp, qp, plen) != 0) return false;
            }
            pp = pe;
            qp = qe;
        }
    }
}

/* ── Header accessor (always available, custom router too) ─────────── */

/** @brief Case-insensitive header name match helper. */
static bool header_name_match(const char* raw, const char* name, size_t name_len) {
    for (size_t i = 0; i < name_len; i++) {
        char a = raw[i];
        char b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return false;
    }
    return true;
}

/** @brief Look up a request header by name (case-insensitive). Returns empty string if not found. */
orbit_string orbit_http_header_get(OrbitArena* arena, OrbitRequest* req, orbit_string name) {
    if (!req || !req->headers || !name) return "";
    const char* raw = req->headers;
    size_t name_len = strlen(name);
    while (*raw) {
        while (*raw == '\r' || *raw == '\n') { raw++; }
        if (!*raw || (*raw == '\r' && *(raw + 1) == '\n')) break;
        const char* colon = strchr(raw, ':');
        if (!colon) break;
        size_t hdr_len = (size_t)(colon - raw);
        if (hdr_len == name_len && header_name_match(raw, name, name_len)) {
            const char* val_start = colon + 1;
            while (*val_start == ' ') val_start++;
            const char* val_end = val_start;
            while (*val_end && *val_end != '\r' && *val_end != '\n') val_end++;
            return orbit_string_slice(arena, val_start, 0, (orbit_int)(val_end - val_start));
        }
        const char* eol = strstr(raw, "\r\n");
        if (!eol) break;
        raw = eol + 2;
    }
    return "";
}

#ifndef ORBIT_CUSTOM_ROUTER
/** @brief Default request dispatcher: handles /_pulse routes internally and returns 404 for everything else.  Returns 1 to keep the connection alive, 0 to close. */
int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed) {
    uint64_t start = orbit_rdtsc();
    orbit_perf_start_request();

    OrbitRequest* req = NULL;
    size_t consumed = orbit_http_parse_request(arena, raw_request, raw_len, &req);
    if (out_consumed) *out_consumed = consumed;
    if (!req) return 1;
    
    int keep_alive = 1;
    // Check if client explicitly asked to close
    if (strstr(raw_request, "Connection: close") || strstr(raw_request, "connection: close")) {
        keep_alive = 0;
    }
    
    // â”€â”€ System Routes: Orbit Pulse â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (req->path && strcmp(req->path, "/_pulse") == 0) {
        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
        orbit_send_response(client_sock, res);
        orbit_perf_end_request(start);
        return keep_alive;
    }
    
    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
        orbit_string json = orbit_pulse_get_stats_json(arena);
        OrbitResponse* res = orbit_response_json(arena, 200, json);
        orbit_send_response(client_sock, res);
        orbit_perf_end_request(start);
        return keep_alive;
    }

    // â”€â”€ Application Routes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
    orbit_send_response(client_sock, res);

    orbit_perf_end_request(start);
    return keep_alive;
}

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

static int http_client_send_all(orbit_socket_t s, const char* buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        int n = send(s, buf + sent, (int)(len - sent), 0);
        if (n <= 0) return 0;
        sent += (size_t)n;
    }
    return 1;
}

/* Connect with a bounded wait. A blocking connect hangs for OS minutes
 * on a blackhole route, so the socket goes non-blocking, select waits
 * for writability, and SO_ERROR says whether the connection is real. */
static int http_client_connect(orbit_socket_t s, struct sockaddr* addr, socklen_t addrlen, int timeout_ms) {
#ifdef _WIN32
    u_long mode = 1;
    if (ioctlsocket(s, FIONBIO, &mode) != 0) return 0;
#else
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0) return 0;
    if (fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) return 0;
#endif
    {
        int rc = connect(s, addr, (int)addrlen);
        if (rc != 0) {
#ifdef _WIN32
            if (WSAGetLastError() != WSAEWOULDBLOCK) return 0;
#else
            if (errno != EINPROGRESS) return 0;
#endif
            {
                fd_set wfds;
                struct timeval tv;
                int sel;
                int nfds = 0;
                FD_ZERO(&wfds);
                FD_SET(s, &wfds);
                tv.tv_sec = timeout_ms / 1000;
                tv.tv_usec = (timeout_ms % 1000) * 1000;
#ifndef _WIN32
                /* Winsock ignores the first select argument; POSIX needs it. */
                nfds = (int)(s + 1);
#endif
                sel = select(nfds, NULL, &wfds, NULL, &tv);
                if (sel <= 0) return 0;
                {
                    int soerr = 0;
                    socklen_t optlen = (socklen_t)sizeof(soerr);
                    if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char*)&soerr, &optlen) != 0) return 0;
                    if (soerr != 0) return 0;
                }
            }
        }
    }
#ifdef _WIN32
    {
        u_long mode = 0;
        if (ioctlsocket(s, FIONBIO, &mode) != 0) return 0;
    }
#else
    {
        int flags = fcntl(s, F_GETFL, 0);
        if (flags < 0) return 0;
        if (fcntl(s, F_SETFL, flags & ~O_NONBLOCK) < 0) return 0;
    }
#endif
    return 1;
}

/* Growable arena buffer: the arena has no realloc, so growth copies
 * forward and abandons the old block (runtime/file.c does the same). */
typedef struct {
    char* data;
    size_t len;
    size_t cap;
    OrbitArena* arena;
    int failed;
} HttpBuf;

static void http_buf_reserve(HttpBuf* b, size_t extra) {
    size_t need;
    size_t next;
    char* grown;
    if (b->failed) return;
    need = b->len + extra;
    if (need <= b->cap) return;
    next = b->cap ? b->cap : 4096;
    while (next < need) next *= 2;
    grown = (char*)orbit_alloc(b->arena, next);
    if (!grown) {
        b->failed = 1;
        return;
    }
    if (b->len) memcpy(grown, b->data, b->len);
    b->data = grown;
    b->cap = next;
}

static void http_buf_append(HttpBuf* b, const char* src, size_t n) {
    if (b->failed || n == 0) return;
    http_buf_reserve(b, n);
    if (b->failed) return;
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

/* Find "\r\n\r\n" in b->data; the offset just past it, or -1. */
static long http_headers_end(HttpBuf* b) {
    size_t i = 0;
    while (i + 3 < b->len) {
        if (b->data[i] == '\r' && b->data[i + 1] == '\n' && b->data[i + 2] == '\r' && b->data[i + 3] == '\n') {
            return (long)(i + 4);
        }
        i++;
    }
    return -1;
}

/* Decimal Content-Length, or -1 when absent or malformed. One
 * case-insensitive search (three spellings would triple-scan for no
 * reason); the value must be all digits, at most ten of them, so the
 * accumulation cannot overflow a long. */
static long http_content_length(const char* head, size_t head_len) {
    static const char name[] = "content-length:";
    size_t nl = sizeof(name) - 1;
    size_t i = 0;
    while (i + nl <= head_len) {
        size_t k = 0;
        while (k < nl) {
            char a = head[i + k];
            char b2 = name[k];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (a != b2) break;
            k++;
        }
        if (k == nl) {
            const char* v = head + i + nl;
            const char* hend = head + head_len;
            long n = 0;
            int digits = 0;
            while (v < hend && (*v == ' ' || *v == '\t')) v++;
            if (v >= hend || *v < '0' || *v > '9') {
                i++;
                continue;
            }
            while (v < hend && *v >= '0' && *v <= '9') {
                n = n * 10 + (*v - '0');
                digits++;
                if (digits > 10) return -1;
                v++;
            }
            return n;
        }
        i++;
    }
    return -1;
}

/* True when the Transfer-Encoding header's value is exactly the chunked
 * coding (case-insensitive, optional parameters after ';' allowed). A
 * substring search would fire on any header that merely mentions the
 * word; the value is what the framing decision must read. */
static int http_is_chunked(const char* head, size_t head_len) {
    static const char name[] = "transfer-encoding:";
    size_t nl = sizeof(name) - 1;
    size_t i = 0;
    while (i + nl <= head_len) {
        size_t k = 0;
        while (k < nl) {
            char a = head[i + k];
            char b2 = name[k];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (a != b2) break;
            k++;
        }
        if (k == nl) {
            const char* v = head + i + nl;
            const char* hend = head + head_len;
            while (v < hend && (*v == ' ' || *v == '\t')) v++;
            if ((size_t)(hend - v) >= 7) {
                size_t k2 = 0;
                static const char want[] = "chunked";
                while (k2 < 7) {
                    char a = v[k2];
                    if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
                    if (a != want[k2]) break;
                    k2++;
                }
                if (k2 == 7 && (v + 7 >= hend || v[7] == ';' || v[7] == ',' || v[7] == ' ' || v[7] == '\t' || v[7] == '\r' || v[7] == '\n')) {
                    return 1;
                }
            }
            return 0;
        }
        i++;
    }
    return 0;
}

/* Split http://host[:port][/path]. Host and port come back as arena
 * copies (getaddrinfo needs NUL termination); path is a span into url.
 * https is refused here, where the scheme is known, not attempted. */
static int http_split_url(OrbitArena* a, const char* url, char** host, char** port, const char** path) {
    const char* rest;
    const char* slash;
    const char* colon;
    size_t hostlen;
    if (!url) return 0;
    if (strncmp(url, "http://", 7) == 0) {
        rest = url + 7;
    } else if (strncmp(url, "https://", 8) == 0) {
        return 0;
    } else {
        return 0;
    }
    slash = strchr(rest, '/');
    colon = strchr(rest, ':');
    if (colon && (!slash || colon < slash)) {
        const char* pend;
        long p;
        hostlen = (size_t)(colon - rest);
        pend = colon + 1;
        p = 0;
        if (*pend < '0' || *pend > '9') return 0;
        while (*pend >= '0' && *pend <= '9') {
            p = p * 10 + (*pend - '0');
            if (p > 65535) return 0;
            pend++;
        }
        if (pend != slash && *pend != '\0') return 0;
        if (p < 1) return 0;
        {
            char* pc = (char*)orbit_alloc(a, 8);
            if (!pc) return 0;
            snprintf(pc, 8, "%ld", p);
            *port = pc;
        }
    } else {
        hostlen = slash ? (size_t)(slash - rest) : strlen(rest);
        {
            char* pc = (char*)orbit_alloc(a, 8);
            if (!pc) return 0;
            memcpy(pc, "80", 3);
            *port = pc;
        }
    }
    if (hostlen == 0 || hostlen > 255) return 0;
    {
        char* h = (char*)orbit_alloc(a, hostlen + 1);
        if (!h) return 0;
        memcpy(h, rest, hostlen);
        h[hostlen] = '\0';
        /* Bracketed [v6] never reaches here: its colons take the port
         * branch above and fail digit parsing, so this stays a plain
         * copy. IPv6 literals are refused, not misparsed. */
        *host = h;
    }
    *path = slash ? slash : "/";
    return 1;
}

ORBIT_UNUSED OrbitResult orbit_http_client_fetch(OrbitArena* arena, orbit_string url) {
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
    char* host = NULL;
    char* port = NULL;
    const char* path = NULL;
    struct addrinfo hints;
    struct addrinfo* addrs = NULL;
    struct addrinfo* ai = NULL;
    orbit_socket_t s = ORBIT_INVALID_SOCKET;
    HttpBuf reply;
    long hend = -1;
    char tmp[4096];
    orbit_http_init();
    if (!url || !http_split_url(a, url, &host, &port, &path)) {
        if (url && strncmp(url, "https://", 8) == 0) {
            return orbit_result_err(ORBIT_ERR_INVALID_ARG, "fetch: https unsupported, no TLS stack");
        }
        return orbit_result_err(ORBIT_ERR_INVALID_ARG, "fetch: bad http url");
    }
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &addrs) != 0) {
        return orbit_result_err(ORBIT_ERR_IO, "fetch: dns failed");
    }
    if (!addrs) {
        return orbit_result_err(ORBIT_ERR_IO, "fetch: dns failed");
    }
    for (ai = addrs; ai; ai = ai->ai_next) {
        s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == ORBIT_INVALID_SOCKET) continue;
        if (http_client_connect(s, ai->ai_addr, ai->ai_addrlen, ORBIT_HTTP_CLIENT_TIMEOUT_MS)) break;
        orbit_socket_close(s);
        s = ORBIT_INVALID_SOCKET;
    }
    freeaddrinfo(addrs);
    if (s == ORBIT_INVALID_SOCKET) {
        return orbit_result_err(ORBIT_ERR_IO, "fetch: connect failed");
    }
    orbit_set_recv_timeout(s, ORBIT_HTTP_CLIENT_TIMEOUT_MS);
    {
        char* rq = (char*)orbit_alloc(a, strlen(path) + strlen(host) + 128);
        int rn;
        if (!rq) {
            orbit_socket_close(s);
            return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
        }
        rn = snprintf(rq, strlen(path) + strlen(host) + 128,
                      "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: orbit/0.1\r\nConnection: close\r\n\r\n",
                      path, host);
        if (rn <= 0 || !http_client_send_all(s, rq, (size_t)rn)) {
            orbit_socket_close(s);
            return orbit_result_err(ORBIT_ERR_IO, "fetch: send failed");
        }
    }
    reply.data = NULL;
    reply.len = 0;
    reply.cap = 0;
    reply.arena = a;
    reply.failed = 0;
    for (;;) {
        int n = recv(s, tmp, sizeof(tmp), 0);
        if (n < 0) {
            orbit_socket_close(s);
            return orbit_result_err(ORBIT_ERR_IO, "fetch: recv failed");
        }
        if (n == 0) break;
        http_buf_append(&reply, tmp, (size_t)n);
        if (reply.failed) {
            orbit_socket_close(s);
            return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
        }
        if (hend < 0) {
            hend = http_headers_end(&reply);
            if (hend < 0 && reply.len > 65536) {
                orbit_socket_close(s);
                return orbit_result_err(ORBIT_ERR_PARSE, "fetch: header block too big");
            }
        }
    }
    orbit_socket_close(s);
    if (hend < 0) {
        hend = http_headers_end(&reply);
        if (hend < 0) {
            return orbit_result_err(ORBIT_ERR_PARSE, "fetch: no header block");
        }
    }
    if (reply.len < 5 || strncmp(reply.data, "HTTP/", 5) != 0) {
        return orbit_result_err(ORBIT_ERR_PARSE, "fetch: bad status line");
    }
    {
        const char* head = reply.data;
        size_t head_len = (size_t)hend;
        const char* body = reply.data + hend;
        size_t have = reply.len - (size_t)hend;
        if (http_is_chunked(head, head_len)) {
            HttpBuf out;
            const char* p = body;
            const char* end = reply.data + reply.len;
            out.data = NULL;
            out.len = 0;
            out.cap = 0;
            out.arena = a;
            out.failed = 0;
            for (;;) {
                const char* eol = p;
                long size = 0;
                while (eol < end && *eol != '\r' && *eol != '\n') eol++;
                {
                    const char* q = p;
                    int digits = 0;
                    if (q < eol && (q[0] == '+' || q[0] == '-')) {
                        return orbit_result_err(ORBIT_ERR_PARSE, "fetch: bad chunk");
                    }
                    /* Eight hex digits already address 4 GB; more is not
                     * a chunk, it is an overflow of the accumulator. */
                    while (q < eol && *q != ';') {
                        int v = -1;
                        if (*q >= '0' && *q <= '9') v = *q - '0';
                        else if (*q >= 'a' && *q <= 'f') v = *q - 'a' + 10;
                        else if (*q >= 'A' && *q <= 'F') v = *q - 'A' + 10;
                        else {
                            return orbit_result_err(ORBIT_ERR_PARSE, "fetch: bad chunk");
                        }
                        if (digits >= 8) {
                            return orbit_result_err(ORBIT_ERR_PARSE, "fetch: chunk too big");
                        }
                        size = size * 16 + v;
                        digits++;
                        q++;
                    }
                }
                p = eol;
                if (p + 1 < end && p[0] == '\r' && p[1] == '\n') p += 2;
                else if (p < end && (*p == '\r' || *p == '\n')) p += 1;
                else {
                    return orbit_result_err(ORBIT_ERR_PARSE, "fetch: bad chunk");
                }
                if (size == 0) break;
                if ((size_t)(end - p) < (size_t)size) {
                    return orbit_result_err(ORBIT_ERR_PARSE, "fetch: short chunk");
                }
                http_buf_append(&out, p, (size_t)size);
                if (out.failed) {
                    return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
                }
                p += size;
                if (p + 1 < end && p[0] == '\r' && p[1] == '\n') p += 2;
                else if (p < end && (*p == '\r' || *p == '\n')) p += 1;
                else {
                    return orbit_result_err(ORBIT_ERR_PARSE, "fetch: bad chunk");
                }
            }
            {
                char* ans = (char*)orbit_alloc(a, out.len + 1);
                if (!ans) {
                    return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
                }
                if (out.len) memcpy(ans, out.data, out.len);
                ans[out.len] = '\0';
                return orbit_result_ok(ans);
            }
        }
        {
            long want = http_content_length(head, head_len);
            if (want >= 0) {
                if (have < (size_t)want) {
                    return orbit_result_err(ORBIT_ERR_PARSE, "fetch: short body");
                }
                {
                    char* ans = (char*)orbit_alloc(a, (size_t)want + 1);
                    if (!ans) {
                        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
                    }
                    if (want) memcpy(ans, body, (size_t)want);
                    ans[want] = '\0';
                    return orbit_result_ok(ans);
                }
            }
        }
        {
            char* ans = (char*)orbit_alloc(a, have + 1);
            if (!ans) {
                return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "fetch: alloc failed");
            }
            if (have) memcpy(ans, body, have);
            ans[have] = '\0';
            return orbit_result_ok(ans);
        }
    }
}


#endif
