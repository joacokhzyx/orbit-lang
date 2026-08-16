/**
 * @file  http_dispatch_latency_shim.c
 * @brief Compilation shim for the HTTP dispatch latency micro-benchmark.
 *
 * Includes the Orbit C runtime HTTP parser (`../src/runtime/http.c`) as a
 * single translation unit.  `http.c`'s own `OrbitRequest` typedef sits inside
 * a nested include guard that never evaluates, so the struct is declared here
 * first (identical layout to the definition in `../src/runtime/builtins.c`).
 *
 * `ORBIT_CUSTOM_ROUTER` skips the socket-bound dispatch hook
 * (`orbit_handle_request`), which requires a connected client socket, and its
 * header accessor (which references a helper that lives in `collections.c`).
 * The benchmark measures the network-free parse/dispatch path exposed by
 * `orbit_http_parse_request()`.
 *
 * `string_pool.c` is pulled in because `arena.c` (included by `http.c`)
 * references its static helpers `orbit_string_pool_local_destroy/reset`.
 * `oracle.c` is compiled separately in `build.zig` to provide the
 * `tls_oracle_session` backing store referenced by `arena.c`.
 */
#define WIN32_LEAN_AND_MEAN 1
#include <stddef.h>
#include <stdint.h>

#include "../src/runtime/performance.h"

#ifndef ORBIT_HTTP_H
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

#define ORBIT_CUSTOM_ROUTER 1

#include "../src/runtime/http.c"
#include "../src/runtime/string_pool.c"

/* Backing store for the TLS oracle session referenced by arena.c; normally
 * provided by src/runtime/oracle.c, which this benchmark does not link. */
#ifdef _MSC_VER
__declspec(thread) OracleSession tls_oracle_session = {0};
#else
__thread OracleSession tls_oracle_session = {0};
#endif