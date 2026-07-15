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

#pragma comment(lib, "ws2_32.lib")

/* ──────────────────────────────────────────────────────────────────────
 * Orbit HTTP — Arena-backed request/response handling.
 *
 * All buffers are allocated from the request Arena, not stack-fixed.
 * This means request size is limited only by Arena capacity, not
 * by hardcoded buffer constants.
 * ────────────────────────────────────────────────────────────────────── */

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
}

/** @brief Shut down the HTTP layer (stops Winsock on Windows; no-op on POSIX). */
void orbit_http_cleanup(void) {
#ifdef _WIN32
    WSACleanup();
#endif
}

/* ── Parse raw HTTP into Arena-allocated OrbitRequest ────────────── */

size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req) {
    if (out_req) *out_req = NULL;
    
    // Ensure we have a complete HTTP request header
    const char* headers_end = strstr(raw, "\r\n\r\n");
    if (!headers_end) return 0;
    
    OrbitRequest* req = (OrbitRequest*)orbit_alloc(arena, sizeof(OrbitRequest));
    if (!req) return 0;
    memset(req, 0, sizeof(OrbitRequest));

    /* Method (until first space) */
    const char* space = memchr(raw, ' ', raw_len);
    if (!space) return 0;

    size_t method_len = (size_t)(space - raw);
    req->method = (char*)orbit_alloc(arena, method_len + 1);
    if (req->method) {
        memcpy(req->method, raw, method_len);
        req->method[method_len] = '\0';
    }

    /* Path (between first and second space) */
    const char* path_start = space + 1;
    const char* path_end = memchr(path_start, ' ', raw_len - (size_t)(path_start - raw));
    if (!path_end) path_end = path_start;

    /* Split path from query string at '?' */
    const char* query = memchr(path_start, '?', (size_t)(path_end - path_start));
    size_t path_len = query ? (size_t)(query - path_start) : (size_t)(path_end - path_start);

    req->path = (char*)orbit_alloc(arena, path_len + 1);
    if (req->path) {
        memcpy(req->path, path_start, path_len);
        req->path[path_len] = '\0';
    }

    if (query) {
        size_t query_len = (size_t)(path_end - query - 1);
        req->query = (char*)orbit_alloc(arena, query_len + 1);
        if (req->query) {
            memcpy(req->query, query + 1, query_len);
            req->query[query_len] = '\0';
        }
    }

    /* Body (after \r\n\r\n) */
    const char* body_sep = headers_end;
    size_t consumed = (size_t)((headers_end + 4) - raw);
    
    const char* body_start = body_sep + 4;
    
    // Find Content-Length in headers
    size_t content_length = 0;
    const char* cl_hdr = strstr(raw, "Content-Length:");
    if (!cl_hdr) cl_hdr = strstr(raw, "content-length:");
    if (cl_hdr && cl_hdr < body_sep) {
        content_length = (size_t)atol(cl_hdr + 15);
    }
    
    // If we don't have the full body yet, we must return 0 to wait for more data
    if (raw_len < consumed + content_length) {
        if (out_req) *out_req = NULL;
        return 0; // Incomplete body
    }
    
    req->body_len = content_length;
        if (req->body_len > 0) {
            req->body = (char*)orbit_alloc(arena, req->body_len + 1);
            if (req->body) {
                memcpy(req->body, body_start, req->body_len);
                req->body[req->body_len] = '\0';
            }
        }
        consumed = (size_t)(body_start - raw) + content_length;

    if (out_req) *out_req = req;
    return consumed;
}

/* ── Response builders ─────────────────────────────────────────────── */

/** @brief Create an arena-allocated OrbitResponse with the given @p status, @p content_type, and @p body. */
OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body) {
    OrbitResponse* resp = (OrbitResponse*)orbit_alloc(arena, sizeof(OrbitResponse));
    if (!resp) return NULL;

    resp->status = status;
    resp->content_type = orbit_arena_strdup(arena, content_type);
    resp->body = body ? orbit_arena_strdup(arena, body) : NULL;
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

/* ── Send response to socket ───────────────────────────────────────── */

/** @brief Write @p resp (header + body) to @p client, checking the Kynx response-size budget when networking is enabled. */
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

    /* Build header dynamically */
    char header[512];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 %d OK\r\n"
        "Content-Type: %s\r\n"
        "Connection: keep-alive\r\n"
        "Keep-Alive: timeout=30, max=1000\r\n"
        "Content-Length: %d\r\n"
        "\r\n",
        resp->status, ct, (int)body_len);

    if (header_len > 0) {
        size_t total_len = (size_t)header_len + body_len;
        if (total_len < 4096) {
            char combined[4096];
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

/* ── Main Dispatch Hook ────────────────────────────────────────────── */

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
    
    // ── System Routes: Orbit Pulse ───────────────────────────────────
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

    // ── Application Routes ───────────────────────────────────────────
    OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
    orbit_send_response(client_sock, res);
    
    orbit_perf_end_request(start);
    return keep_alive;
}
#endif

#endif
