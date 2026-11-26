#ifndef ORBIT_HTTP_SERVER_H
#define ORBIT_HTTP_SERVER_H

#include "socket_compat.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct OrbitArena;

/* The worker owns raw and arena. The callback may use both until it returns.
 * Report bytes consumed separately from whether the connection stays open. */
typedef int (*OrbitHttpRequestFn)(orbit_socket_t client, const char* raw,
                                  size_t size, struct OrbitArena* arena,
                                  size_t* consumed, const char* peer);
typedef void (*OrbitHttpReadyFn)(int port, int workers, int admission, double ready_ms);

typedef struct {
    int port;
    bool admission;
    bool flush_logs;
    bool show_admission;
    uint64_t start_cycles;
    OrbitHttpRequestFn request;
    OrbitHttpReadyFn ready;
} OrbitHttpServerConfig;

/* Serve until shutdown. The caller owns HTTP and admission initialization
 * and keeps config alive until all workers have joined. */
int orbit_http_serve(const OrbitHttpServerConfig* config);
void orbit_admission_peer_ip_string(orbit_socket_t socket, char* out, size_t size);

#endif
