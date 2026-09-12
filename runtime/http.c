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
typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
} OrbitRequest;
#endif

/** @brief Parse a raw HTTP byte stream into an arena-allocated OrbitRequest; returns bytes consumed, or 0 if the request is incomplete. */
size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req);
size_t orbit_http_parse_request_ex(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req, int* out_parse_error);


typedef struct {
    int    status;
    char*  body;
    size_t body_len;
    char*  content_type;
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
     * keeps translation units that include http.c without energy.c (such as
     * the dispatch micro-benchmark shim) compiling unchanged. */
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
    return resp;
}

/** @brief Convenience wrapper: create a JSON response with Content-Type application/json. */
OrbitResponse* orbit_response_json(OrbitArena* arena, int status, const char* json) {
    return orbit_response_create(arena, status, "application/json", json);
}

/** @brief Convenience wrapper: create a plain-text response with Content-Type text/plain. */
OrbitResponse* orbit_response_text(OrbitArena* arena, int status, const char* text) {
    return orbit_response_create(arena, status, "text/plain", text);
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
    int header_len;
    if (reason_len <= 32 && ct_len <= 128) {
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
        memcpy(h, h3, sizeof(h3) - 1); h += sizeof(h3) - 1;
        h = orbit_append_int(h, (int)body_len);
        memcpy(h, h4, sizeof(h4) - 1); h += sizeof(h4) - 1;
        header_len = (int)(h - header);
    } else {
        header_len = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\n"
            "Server: Orbit\r\n"
            "Content-Type: %s\r\n"
            "Connection: keep-alive\r\n"
            "Keep-Alive: timeout=30, max=1000\r\n"
            "Content-Length: %d\r\n"
            "\r\n",
            resp->status, reason, ct, (int)body_len);
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
/* â”€â”€ Header accessor â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

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

#endif

#endif
