#ifndef ORBIT_HTTP_NATIVE_H
#define ORBIT_HTTP_NATIVE_H

#include "http.h"

/* The read-only image starts with six little-endian u32 fields per route.
 * Method and path are offsets from the image base to terminated strings.
 * The following words are rate, window milliseconds, burst and match kind.
 * The compiler orders the entries exact, single-segment, then multi-segment
 * and retains declaration order within each kind. */
enum {
    ORBIT_NATIVE_ROUTE_METHOD,
    ORBIT_NATIVE_ROUTE_PATH,
    ORBIT_NATIVE_ROUTE_RATE,
    ORBIT_NATIVE_ROUTE_WINDOW,
    ORBIT_NATIVE_ROUTE_BURST,
    ORBIT_NATIVE_ROUTE_KIND,
    ORBIT_NATIVE_ROUTE_WORDS
};

typedef OrbitResponse* (*OrbitNativeRouteFn)(size_t route, OrbitArena* arena, OrbitRequest* request);
typedef int (*OrbitNativeMainFn)(OrbitArena* arena);
enum {
    ORBIT_NATIVE_HTTP_ADMISSION = 1,
    ORBIT_NATIVE_HTTP_LOGS = 2
};

int orbit_http_run_native(int argc, char** argv, int default_port,
                          const unsigned char* routes, size_t count,
                          OrbitNativeRouteFn dispatch, OrbitNativeMainFn main_fn,
                          unsigned flags);
OrbitArena* orbit_http_native_arena(void);

#endif
