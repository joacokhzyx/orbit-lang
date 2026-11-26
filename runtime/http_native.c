#include "http_native.h"
#include "http_server.h"
#include "admission.h"
#include "arena_pool.h"
#include "crash.h"
#include "ledger.h"
#include "performance.h"

typedef struct {
    const unsigned char* routes;
    size_t count;
    OrbitNativeRouteFn dispatch;
    bool admission;
    bool logs;
} OrbitNativeService;

static const OrbitNativeService* native_service;
static __thread OrbitArena* native_arena;

OrbitArena* orbit_http_native_arena(void) {
    return native_arena;
}

static uint32_t route_word(const unsigned char* entry, unsigned field) {
    const unsigned char* bytes = entry + field * 4;
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static const unsigned char* route_entry(const OrbitNativeService* service, size_t index) {
    return service->routes + index * ORBIT_NATIVE_ROUTE_WORDS * 4;
}

static const char* route_text(const OrbitNativeService* service,
                              const unsigned char* entry, unsigned field) {
    return (const char*)service->routes + route_word(entry, field);
}

static size_t native_find_route(const OrbitNativeService* service,
                                OrbitArena* arena, OrbitRequest* request) {
    for (size_t index = 0; index < service->count; index++) {
        const unsigned char* entry = route_entry(service, index);
        const char* method = route_text(service, entry, ORBIT_NATIVE_ROUTE_METHOD);
        const char* path = route_text(service, entry, ORBIT_NATIVE_ROUTE_PATH);
        if (strcmp(request->method, method) != 0) continue;
        bool matches = route_word(entry, ORBIT_NATIVE_ROUTE_KIND) == 0
            ? strcmp(request->path, path) == 0
            : orbit_route_match(arena, request, method, path);
        if (matches) return index;
    }
    return SIZE_MAX;
}

static void native_register_limits(const OrbitNativeService* service) {
    if (!service->admission) return;
    for (size_t i = 0; i < service->count; i++) {
        const unsigned char* entry = route_entry(service, i);
        int rate = (int)route_word(entry, ORBIT_NATIVE_ROUTE_RATE);
        if (rate > 0) orbit_admission_register_route_limit(
            route_text(service, entry, ORBIT_NATIVE_ROUTE_METHOD),
            route_text(service, entry, ORBIT_NATIVE_ROUTE_PATH), rate,
            (int)route_word(entry, ORBIT_NATIVE_ROUTE_WINDOW),
            (int)route_word(entry, ORBIT_NATIVE_ROUTE_BURST));
    }
}

static OrbitResponse* native_dispatch(const OrbitNativeService* service,
                                       orbit_socket_t client, OrbitArena* arena,
                                       OrbitRequest* request) {
    if (strcmp(request->path, "/_pulse") == 0)
        return orbit_response_html(arena, 200, ORBIT_PULSE_DASHBOARD_HTML);
    if (strcmp(request->path, "/_pulse/data") == 0)
        return orbit_response_json(arena, 200, orbit_pulse_get_stats_json(arena));
    bool ledger_data = strcmp(request->path, "/_ledger/data") == 0;
    if (ledger_data || strcmp(request->path, "/_ledger") == 0) {
        uint64_t entered = orbit_rdtsc();
        int ledger = orbit_ledger_enter(request->method, request->path);
        OrbitResponse* response;
        if (!orbit_ledger_is_loopback(client))
            response = orbit_response_error(arena, 403, "Forbidden: /_ledger serves loopback only.");
        else if (ledger_data)
            response = orbit_response_json(arena, 200, orbit_ledger_json(arena));
        else
            response = orbit_response_html(arena, 200, orbit_ledger_html(arena));
        orbit_ledger_exit(ledger, orbit_rdtsc() - entered, arena);
        return response;
    }

    size_t index = native_find_route(service, arena, request);
    if (index == SIZE_MAX) return orbit_response_error(arena, 404, "Not Found");
    uint64_t entered = orbit_rdtsc();
    int ledger = orbit_ledger_enter(request->method, request->path);
    OrbitResponse* response = service->dispatch(index, arena, request);
    orbit_ledger_exit(ledger, orbit_rdtsc() - entered, arena);
    return response;
}

static OrbitResponse* admission_refusal(OrbitArena* arena, OrbitRequest* request,
                                        orbit_socket_t client, const char* peer,
                                        char* effective_ip, size_t size) {
    char socket_peer[64];
    if (!peer || !peer[0]) {
        orbit_admission_peer_ip_string(client, socket_peer, sizeof(socket_peer));
        peer = socket_peer;
    }
    const char* forwarded = NULL;
    if (orbit_admission_has_trusted_proxies())
        forwarded = orbit_http_header_get(arena, request, "X-Forwarded-For");
    orbit_admission_effective_ip(peer, forwarded, effective_ip, size);
    if (orbit_admission_check_route(effective_ip, request->method, request->path)) return NULL;

    int seconds = (orbit_admission_last_retry_ms() + 999) / 1000;
    char retry[16];
    snprintf(retry, sizeof(retry), "%d", seconds < 1 ? 1 : seconds);
    OrbitResponse* response = orbit_response_error(arena, 429, "429 Too Many Requests - admission control");
    orbit_response_add_header(arena, response, "Retry-After", retry);
    return orbit_response_or_500(arena, response);
}

static int native_request(orbit_socket_t client, const char* raw, size_t size,
                          OrbitArena* arena, size_t* consumed, const char* peer) {
    const OrbitNativeService* service = native_service;
    uint64_t start = orbit_rdtsc();
    orbit_perf_start_request();
    OrbitRequest* request = NULL;
    int error = 0;
    *consumed = orbit_http_parse_request_ex(arena, raw, size, &request, &error);
    if (error) {
        orbit_send_response(client, orbit_response_or_500(arena, orbit_http_parse_error_response(arena, error)));
        orbit_perf_end_request(start);
        return 0;
    }
    if (!request) return 1;

    int keep = !strstr(raw, "Connection: close") && !strstr(raw, "connection: close");
    OrbitResponse* response = NULL;
    OrbitAdmissionLease* lease = NULL;
    const char* log_method = request->method;
    const char* log_path = request->path;
    char effective_ip[64] = {0};
    if (service->admission) {
        response = admission_refusal(arena, request, client, peer, effective_ip, sizeof(effective_ip));
        if (response) {
            log_method = "ADMISSION";
            log_path = effective_ip;
            keep = 0;
        } else {
            lease = orbit_admission_lease_create_for_route(request->path, request->method, arena);
            if (lease && (lease->flags & 1)) {
                response = orbit_response_or_500(arena, orbit_response_error(
                    arena, 503, "503 Siege Mode Active - Non-critical Route Blocked"));
                keep = 0;
            }
        }
    }
    if (!response) {
        native_arena = arena;
        response = native_dispatch(service, client, arena, request);
        native_arena = NULL;
    }
    response = orbit_response_or_500(arena, response);
    orbit_send_response(client, response);
    if (service->logs)
        printf("%s %s %d\n", log_method, log_path, response ? response->status : 500);
    if (lease) orbit_admission_lease_destroy(lease);
    orbit_perf_end_request(start);
    return keep;
}

static void native_ready(int port, int workers, int admission, double milliseconds) {
    printf("\n   - Local: http://localhost:%d\n   - Workers: %d\n", port, workers);
    if (admission) printf("   - Admission control on\n");
    printf("\n- Ready in %.1f ms\n\n", milliseconds);
    fflush(stdout);
}

static int native_port(int argc, char** argv, int fallback) {
    if (argc < 2) return fallback;
    char* end = NULL;
    long port = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end || port < 0 || port > 65535) {
        fprintf(stderr, "The port has to be a number between 0 and 65535, not \"%s\". 0 asks the system for a free port.\n", argv[1]);
        return -1;
    }
    return (int)port;
}

int orbit_http_run_native(int argc, char** argv, int default_port,
                          const unsigned char* routes, size_t count,
                          OrbitNativeRouteFn dispatch, OrbitNativeMainFn main_fn,
                          unsigned flags) {
    const OrbitNativeService service = {routes, count, dispatch,
                                        (flags & ORBIT_NATIVE_HTTP_ADMISSION) != 0,
                                        (flags & ORBIT_NATIVE_HTTP_LOGS) != 0};
    const OrbitAdmissionConfig admission = {
        .pool_size = 512, .rate_limit = 50, .window_ms = 1000,
        .ban_threshold = 200, .score_increment = 10, .score_decay = 1,
        .enabled = true
    };
    uint64_t start = orbit_rdtsc();
    orbit_crash_handler_install();
    orbit_http_init();
    orbit_ledger_enable_file_dump();
    orbit_arena_pool_init(16, 131072);
    orbit_admission_init(admission);
    native_register_limits(&service);
    native_arena = orbit_arena_pool_acquire();
    int exit_code = main_fn ? main_fn(native_arena) : 0;
    orbit_arena_pool_release(native_arena);
    native_arena = NULL;

    int port = native_port(argc, argv, default_port);
    int status = 2;
    if (port >= 0) {
        const OrbitHttpServerConfig config = {
            .port = port, .admission = service.admission, .flush_logs = service.logs,
            .show_admission = service.admission, .start_cycles = start,
            .request = native_request, .ready = native_ready
        };
        native_service = &service;
        status = orbit_http_serve(&config);
        native_service = NULL;
    }
    orbit_admission_cleanup();
    orbit_arena_pool_cleanup();
    orbit_http_cleanup();
    return status ? status : exit_code;
}
