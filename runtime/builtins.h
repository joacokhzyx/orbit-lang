/* Interface of runtime/builtins.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_BUILTINS_H
#define ORBIT_RT_BUILTINS_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "types.h"
#include "arena.h"
#include "performance.h"
#include "crt_compat.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <time.h>
#include <ctype.h>
#ifdef _WIN32
#  include <windows.h>
#else
#  include <unistd.h>
#endif
void orbit_print(const char* str);
orbit_int orbit_string_to_int(orbit_string s);
orbit_float orbit_string_to_float(orbit_string s);
orbit_int orbit_clock_ns(void);
orbit_int orbit_clock_ms(void);
orbit_int orbit_wall_seconds(void);
void orbit_sleep_ms(orbit_int ms);

/* ── HTTP query parameter extraction ──────────────────────────────────────── */

/* Forward-declare OrbitRequest so builtins.c can reference it without
 * pulling in the entire HTTP stack (which has its own include guards). */
#include "http.h"
orbit_string orbit_http_query_get(OrbitArena* arena, OrbitRequest* req, orbit_string key);
OrbitList* orbit_http_query_get_all(OrbitArena* arena, OrbitRequest* req, orbit_string key);
orbit_string orbit_http_param_get(OrbitArena* arena, OrbitRequest* req, orbit_string param_name);
orbit_string orbit_http_body_get(OrbitArena* arena, OrbitRequest* req);
orbit_string orbit_json_field(OrbitArena* arena, orbit_string json, orbit_string key);

/* orbit_http_client_fetch lives in runtime/http.c: a real blocking
 * GET there replaced the mock that used to sit here. */

typedef struct {
    char key[128];
    char val[512];
    uint64_t expires_at;
} OrbitCacheItem;
orbit_string orbit_cache_get(OrbitArena* arena, orbit_string key);
bool orbit_cache_set(orbit_string key, orbit_string val, int64_t ttl);
orbit_string orbit_file_upload_save(OrbitArena* arena, OrbitRequest* req, orbit_string field_name, orbit_string dest_dir);
uint64_t orbit_monotonic_ns(void);
void orbit_system_set_workers(int n);
orbit_int system_uptime(void);
orbit_int system_pid(void);
orbit_int system_active_workers(void);
orbit_int system_http_requests_total(void);
orbit_int system_latency_avg_us(void);
orbit_int system_latency_p50_us(void);
orbit_int system_latency_p95_us(void);
orbit_int system_latency_p99_us(void);
orbit_int system_os_exec(orbit_string cmd);
orbit_string system_env(orbit_string name);

#endif
