/* orbit_http_client_fetch: real GETs against a loopback server.
 *
 * A server thread answers on 127.0.0.1 with an ephemeral port: /len with
 * a Content-Length body, /chunked with a chunked body, anything else 404
 * with a body (still ok: the status is not surfaced, only transport and
 * framing failures are err). Refusals need no server and fail fast:
 * https scheme, unresolvable host (.invalid never resolves, RFC 2606),
 * closed port. Threads are raw platform calls (CreateThread/pthreads):
 * thread_pool.c is server machinery, not a thread library.
 */
#include <stdio.h>
#include <string.h>

#include "runtime.h"

#ifdef _WIN32
static DWORD WINAPI serve_fn(LPVOID arg) {
#else
#include <pthread.h>
static void* serve_fn(void* arg) {
#endif
    orbit_socket_t ls = *(orbit_socket_t*)arg;
    int i;
    for (i = 0; i < 3; i++) {
        orbit_socket_t c = accept(ls, NULL, NULL);
        if (c == ORBIT_INVALID_SOCKET) break;
        {
            char req[4096];
            size_t got = 0;
            int done = 0;
            while (got < sizeof(req) - 1) {
                int n = recv(c, req + got, (int)(sizeof(req) - 1 - got), 0);
                if (n <= 0) break;
                got += (size_t)n;
                req[got] = '\0';
                if (strstr(req, "\r\n\r\n") != NULL) {
                    done = 1;
                    break;
                }
            }
            {
                const char* path = NULL;
                const char* resp;
                if (done && strncmp(req, "GET ", 4) == 0) {
                    const char* s = req + 4;
                    const char* e = strchr(s, ' ');
                    static char pbuf[256];
                    size_t pl = e ? (size_t)(e - s) : 0;
                    if (pl > 0 && pl < sizeof(pbuf)) {
                        memcpy(pbuf, s, pl);
                        pbuf[pl] = '\0';
                        path = pbuf;
                    }
                }
                if (path && strcmp(path, "/len") == 0) {
                    resp = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
                } else if (path && strcmp(path, "/chunked") == 0) {
                    resp = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
                } else {
                    resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found";
                }
                {
                    size_t left = strlen(resp);
                    const char* w = resp;
                    while (left > 0) {
                        int n = send(c, w, (int)left, 0);
                        if (n <= 0) break;
                        w += n;
                        left -= (size_t)n;
                    }
                }
            }
        }
        orbit_socket_close(c);
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

int main(void) {
    int failures = 0;
    orbit_socket_t ls;
    struct sockaddr_in addr;
    int port;
#ifdef _WIN32
    HANDLE th;
#else
    pthread_t th;
#endif

    orbit_http_init();
    ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls == ORBIT_INVALID_SOCKET) {
        printf("FAILED listen socket\n");
        return 1;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(ls, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        printf("FAILED bind loopback\n");
        orbit_socket_close(ls);
        return 1;
    }
    {
        struct sockaddr_in got;
        int len = (int)sizeof(got);
        if (getsockname(ls, (struct sockaddr*)&got, &len) != 0) {
            printf("FAILED getsockname\n");
            orbit_socket_close(ls);
            return 1;
        }
        port = ntohs(got.sin_port);
    }
    if (listen(ls, 8) != 0) {
        printf("FAILED listen\n");
        orbit_socket_close(ls);
        return 1;
    }
#ifdef _WIN32
    th = CreateThread(NULL, 0, serve_fn, &ls, 0, NULL);
    if (th == NULL) {
        printf("FAILED thread\n");
        orbit_socket_close(ls);
        return 1;
    }
#else
    if (pthread_create(&th, NULL, serve_fn, &ls) != 0) {
        printf("FAILED thread\n");
        orbit_socket_close(ls);
        return 1;
    }
#endif
    /* listen() already queues; the thread only accepts. */
    {
        OrbitArena* arena = orbit_arena_create(65536);
        char url[128];
        OrbitResult r;
        snprintf(url, sizeof(url), "http://127.0.0.1:%d/len", port);
        r = orbit_http_client_fetch(arena, url);
        if (!r.ok || strcmp((const char*)r.value, "hello") != 0) {
            printf("FAILED len body: %s\n", r.ok ? (const char*)r.value : "(err)");
            failures++;
        }
        snprintf(url, sizeof(url), "http://127.0.0.1:%d/chunked", port);
        r = orbit_http_client_fetch(arena, url);
        if (!r.ok || strcmp((const char*)r.value, "hello") != 0) {
            printf("FAILED chunked body: %s\n", r.ok ? (const char*)r.value : "(err)");
            failures++;
        }
        snprintf(url, sizeof(url), "http://127.0.0.1:%d/nope", port);
        r = orbit_http_client_fetch(arena, url);
        if (!r.ok || strcmp((const char*)r.value, "not found") != 0) {
            printf("FAILED 404 body: %s\n", r.ok ? (const char*)r.value : "(err)");
            failures++;
        }
        r = orbit_http_client_fetch(arena, "https://127.0.0.1/none");
        if (r.ok) {
            printf("FAILED https accepted\n");
            failures++;
        }
        r = orbit_http_client_fetch(arena, "http://orbit-missing-xyz.invalid/");
        if (r.ok) {
            printf("FAILED bad host accepted\n");
            failures++;
        }
        r = orbit_http_client_fetch(arena, "http://127.0.0.1:1/");
        if (r.ok) {
            printf("FAILED closed port accepted\n");
            failures++;
        }
        r = orbit_http_client_fetch(arena, "not a url");
        if (r.ok) {
            printf("FAILED bad url accepted\n");
            failures++;
        }
        orbit_arena_destroy(arena);
    }
#ifdef _WIN32
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
#else
    pthread_join(th, NULL);
#endif
    orbit_socket_close(ls);
    if (failures == 0) {
        printf("test_http_client: all cases pass\n");
    }
    return failures == 0 ? 0 : 1;
}
