/**
 * @file  demo-ledger-server.c
 * @brief Minimal loopback demo server for the cost ledger and energy sampler.
 *
 * A single-threaded server on the Orbit C runtime (no compiler needed):
 *
 *   gcc -O2 -DORBIT_WITH_NET -I <repo-root> demo-ledger-server.c -o demo -lws2_32   (Windows)
 *   cc  -O2 -DORBIT_WITH_NET -I <repo-root> demo-ledger-server.c -o demo -lpthread  (Linux)
 *   ./demo 18080
 *
 * Routes: GET /hello (static), GET /_ledger (HTML, loopback only),
 * GET /_ledger/data (JSON, loopback only). Every handler is wrapped in
 * orbit_ledger_enter/exit exactly like generated routers. The energy
 * sampler runs for the life of the process via orbit_http_init/cleanup.
 * This is a measurement fixture, not a production server: one connection
 * at a time, keep-alive up to 1000 requests, 30 s receive timeout.
 */
#include <stdio.h>
#include <string.h>

#include "runtime/runtime.h"

#define DEMO_BUF 16384
#define DEMO_KEEPALIVE_MAX 1000

static void demo_handle(orbit_socket_t c, const char* raw, size_t len, OrbitArena* arena) {
    OrbitRequest* req = NULL;
    uint64_t ls = 0;
    int slot = -1;
    OrbitResponse* res = NULL;
    size_t consumed = 0;

    orbit_http_parse_request(arena, raw, len, &req);
    consumed = len;
    (void)consumed;
    if (!req || !req->method || !req->path) {
        res = orbit_response_create(arena, 400, "text/plain", "Bad Request");
        orbit_send_response(c, res);
        return;
    }
    ls = orbit_rdtsc();
    slot = orbit_ledger_enter(req->method, req->path);
    if (strcmp(req->path, "/hello") == 0) {
        res = orbit_response_create(arena, 200, "text/plain", "OK\n");
    } else if (strcmp(req->path, "/_ledger/data") == 0) {
        if (!orbit_ledger_is_loopback(c)) {
            res = orbit_response_create(arena, 403, "text/plain",
                "Forbidden: /_ledger serves loopback only.");
        } else {
            res = orbit_response_json(arena, 200, orbit_ledger_json(arena));
        }
    } else if (strcmp(req->path, "/_ledger") == 0) {
        if (!orbit_ledger_is_loopback(c)) {
            res = orbit_response_create(arena, 403, "text/plain",
                "Forbidden: /_ledger serves loopback only.");
        } else {
            res = orbit_response_create(arena, 200, "text/html", orbit_ledger_html(arena));
        }
    } else {
        res = orbit_response_create(arena, 404, "text/plain", "Not Found");
    }
    orbit_ledger_exit(slot, orbit_rdtsc() - ls);
    orbit_send_response(c, res);
}

int main(int argc, char* argv[]) {
    int port = 18080;
    orbit_socket_t srv;
    struct sockaddr_in addr;
    int reuse = 1;
    OrbitArena* arena = NULL;
    char* buf = NULL;

    if (argc > 1) port = atoi(argv[1]);
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "usage: demo-ledger-server [port]\n");
        return 2;
    }
    orbit_http_init();
    arena = orbit_arena_create(131072);
    buf = (char*)malloc(DEMO_BUF);
    if (!arena || !buf) {
        fprintf(stderr, "demo: out of memory\n");
        return 1;
    }
    srv = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (srv == ORBIT_INVALID_SOCKET) {
        fprintf(stderr, "demo: no socket\n");
        return 1;
    }
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) == ORBIT_SOCKET_ERROR) {
        fprintf(stderr, "demo: port %d unavailable\n", port);
        return 1;
    }
    if (listen(srv, 16) == ORBIT_SOCKET_ERROR) {
        fprintf(stderr, "demo: listen failed\n");
        return 1;
    }
    printf("demo ledger server on http://127.0.0.1:%d (source: %s)\n", port, orbit_energy_source());
    fflush(stdout);
    for (;;) {
        orbit_socket_t c = accept(srv, NULL, NULL);
        int n = 0;
        if (c == ORBIT_INVALID_SOCKET) continue;
        orbit_set_recv_timeout(c, 30000);
        n = 0;
        while (n < DEMO_KEEPALIVE_MAX) {
            int got = recv(c, buf, DEMO_BUF - 1, 0);
            if (got <= 0) break;
            buf[got] = '\0';
            orbit_arena_reset(arena);
            demo_handle(c, buf, (size_t)got, arena);
            n++;
            if (strstr(buf, "Connection: close") || strstr(buf, "connection: close")) break;
        }
        orbit_socket_close(c);
    }
}
