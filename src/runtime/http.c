#ifndef ORBIT_HTTP_H
#define ORBIT_HTTP_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <ws2tcpip.h>
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

typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
} OrbitRequest;

typedef struct {
    int    status;
    char*  body;
    size_t body_len;
    char*  content_type;
} OrbitResponse;

// Forward declaration for Pulsar support
#include "pulse.c"

void orbit_http_init(void) {
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
}

void orbit_http_cleanup(void) {
    WSACleanup();
}

/* ── Parse raw HTTP into Arena-allocated OrbitRequest ────────────── */

OrbitRequest* orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len) {
    OrbitRequest* req = (OrbitRequest*)orbit_alloc(arena, sizeof(OrbitRequest));
    if (!req) return NULL;
    memset(req, 0, sizeof(OrbitRequest));

    /* Method (until first space) */
    const char* space = memchr(raw, ' ', raw_len);
    if (!space) return req;

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
    const char* body_sep = strstr(raw, "\r\n\r\n");
    if (body_sep) {
        const char* body_start = body_sep + 4;
        req->body_len = raw_len - (size_t)(body_start - raw);
        if (req->body_len > 0) {
            req->body = (char*)orbit_alloc(arena, req->body_len + 1);
            if (req->body) {
                memcpy(req->body, body_start, req->body_len);
                req->body[req->body_len] = '\0';
            }
        }
    }

    return req;
}

/* ── Response builders ─────────────────────────────────────────────── */

OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body) {
    OrbitResponse* resp = (OrbitResponse*)orbit_alloc(arena, sizeof(OrbitResponse));
    if (!resp) return NULL;

    resp->status = status;
    resp->content_type = orbit_arena_strdup(arena, content_type);
    resp->body = body ? orbit_arena_strdup(arena, body) : NULL;
    resp->body_len = body ? strlen(body) : 0;
    return resp;
}

OrbitResponse* orbit_response_json(OrbitArena* arena, int status, const char* json) {
    return orbit_response_create(arena, status, "application/json", json);
}

OrbitResponse* orbit_response_text(OrbitArena* arena, int status, const char* text) {
    return orbit_response_create(arena, status, "text/plain", text);
}

/* ── Send response to socket ───────────────────────────────────────── */

void orbit_send_response(SOCKET client, OrbitResponse* resp) {
    if (!resp) return;

    const char* body = resp->body ? resp->body : "";
    size_t body_len  = resp->body_len;
    const char* ct   = resp->content_type ? resp->content_type : "text/plain";

    /* Build header dynamically */
    char header[512];
    int header_len = snprintf(header, sizeof(header),
        "HTTP/1.1 %d OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        resp->status, ct, body_len);

    if (header_len > 0) {
        send(client, header, header_len, 0);
    }
    if (body_len > 0) {
        send(client, body, (int)body_len, 0);
    }
}

/* ── Main Dispatch Hook ────────────────────────────────────────────── */

#ifndef ORBIT_CUSTOM_ROUTER
void orbit_handle_request(SOCKET client_sock, const char* raw_request, OrbitArena* arena) {
    uint64_t start = orbit_rdtsc();
    orbit_perf_start_request();

    OrbitRequest* req = orbit_http_parse_request(arena, raw_request, strlen(raw_request));
    if (!req) return;
    
    // ── System Routes: Orbit Pulse ───────────────────────────────────
    if (req->path && strcmp(req->path, "/_pulse") == 0) {
        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
        orbit_send_response(client_sock, res);
        orbit_perf_end_request(start);
        return;
    }
    
    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
        orbit_string json = orbit_pulse_get_stats_json(arena);
        OrbitResponse* res = orbit_response_json(arena, 200, json);
        orbit_send_response(client_sock, res);
        orbit_perf_end_request(start);
        return;
    }

    // ── Application Routes ───────────────────────────────────────────
    // This is where generated code or the default 404 would go.
    // Since we aren't at the CBackend injection level yet, we'll send a 404 for unknown.
    OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
    orbit_send_response(client_sock, res);
    
    orbit_perf_end_request(start);
}
#endif

#endif
