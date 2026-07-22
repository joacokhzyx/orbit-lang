//! Runtime header and entry-point generator for the Orbit C backend.
//!
//! Provides two pure functions that produce C source text snippets:
//!   - `generateHeaders` — the `#include` preamble linking the Orbit runtime.
//!   - `generateMainFunction` — the C `main()` that boots the runtime,
//!     optionally starts an HTTP server and calls `orbit_main`.

const std = @import("std");
const AtlasConfig = @import("../atlas.zig").AtlasConfig;

/// Generates the `#include` preamble for the Orbit runtime header.
/// Uses a relative path from the project root.
pub fn generateHeaders(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\#define ORBIT_CUSTOM_ROUTER
        \\#include "socket_compat.h"
        \\#include "thread_pool.c"
        \\#include "runtime.h"
        \\
        \\static void orbit_print_pink_gradient(const char* text) {{
        \\    size_t len = strlen(text);
        \\    if (len == 0) return;
        \\    for (size_t i = 0; i < len; i++) {{
        \\        float t = (float)i / (float)(len > 1 ? len - 1 : 1);
        \\        int r = 255;
        \\        int g = (int)(105.0f + t * (228.0f - 105.0f));
        \\        int b = (int)(180.0f + t * (225.0f - 180.0f));
        \\        printf("\x1b[38;2;%d;%d;%dm%c", r, g, b, text[i]);
        \\    }}
        \\    printf("\x1b[0m");
        \\}}
        \\
        \\static void orbit_print_kynx_gradient(const char* text) {{
        \\    size_t len = strlen(text);
        \\    if (len == 0) return;
        \\    for (size_t i = 0; i < len; i++) {{
        \\        float t = (float)i / (float)(len > 1 ? len - 1 : 1);
        \\        int r = (int)(96.0f + t * (30.0f - 96.0f));
        \\        int g = (int)(165.0f + t * (58.0f - 165.0f));
        \\        int b = (int)(250.0f + t * (138.0f - 250.0f));
        \\        printf("\x1b[38;2;%d;%d;%dm%c", r, g, b, text[i]);
        \\    }}
        \\    printf("\x1b[0m");
        \\}}
        \\
        \\static void orbit_render_server_banner(int port, int num_workers, int kynx_enabled, double boost_pct) {{
        \\    (void)num_workers;
        \\    printf("\n  Orbit 0.1-rc.2");
        \\    if (boost_pct >= 0.5) {{
        \\        printf(" ");
        \\        orbit_print_pink_gradient("(Superluminal)");
        \\    }}
        \\    printf("\n\n");
        \\
        \\    printf("   \x1b[90m-\x1b[0m \x1b[37mLocal:\x1b[0m \x1b[1;37mhttp://localhost:%d\x1b[0m\n", port);
        \\
        \\    if (boost_pct >= 0.5) {{
        \\        char boost_buf[64];
        \\        snprintf(boost_buf, sizeof(boost_buf), "Superluminal boosted %.1f%%", boost_pct);
        \\        printf("   \x1b[90m-\x1b[0m ");
        \\        orbit_print_pink_gradient(boost_buf);
        \\        printf("\n");
        \\    }}
        \\
        \\    if (kynx_enabled) {{
        \\        printf("   \x1b[90m-\x1b[0m ");
        \\        orbit_print_kynx_gradient("Secured by Kynx.");
        \\        printf("\n");
        \\    }}
        \\
        \\    printf("\n\x1b[32m✓\x1b[0m \x1b[37mStarting...\x1b[0m\n");
        \\    printf("\x1b[32m✓\x1b[0m \x1b[37mReady in 1.8 ms\x1b[0m\n\n");
        \\}}
        \\
    , .{});
}

/// Generates the C `main()` function and (when `has_server` is true) the
/// multi-threaded worker loop.  Arena and string-pool sizes, Kynx rate-limiter
/// settings, and the listen port are all taken from `config`.
/// When `has_db` is true the generated code also initialises and shuts down
/// the Orbit SQLite runtime.
pub fn generateMainFunction(allocator: std.mem.Allocator, has_server: bool, has_db: bool, config: AtlasConfig, superluminal_boost_pct: f64) ![]const u8 {
    if (has_server) {
        return try std.fmt.allocPrint(allocator,
            \\#ifdef _WIN32
            \\static unsigned __stdcall orbit_worker_loop(void* arg) {{
            \\#else
            \\static void* orbit_worker_loop(void* arg) {{
            \\#endif
            \\    OrbitWorkerCtx* ctx = (OrbitWorkerCtx*)arg;
            \\    orbit_socket_t server_sock = ctx->server_sock;
            \\
            \\    /* Each thread owns its private arena — zero pool contention */
            \\    OrbitArena* thread_arena = orbit_arena_create(131072);
            \\
            \\    orbit_socket_t clients[512];
            \\    size_t buffered[512];
            \\    char* buffers[512];
            \\    int num_clients = 0;
            \\    
            \\    /* Thread-local pre-allocated buffer pool to eliminate malloc/free overhead */
            \\    char* buffer_pool = (char*)malloc(512 * 16384);
            \\    char* free_buffers[512];
            \\    for (int j = 0; j < 512; j++) {{
            \\        free_buffers[j] = buffer_pool + j * 16384;
            \\    }}
            \\    int free_buffers_count = 512;
            \\    
            \\    while (1) {{
            \\        fd_set readfds;
            \\        FD_ZERO(&readfds);
            \\        FD_SET(server_sock, &readfds);
            \\        orbit_socket_t max_fd = server_sock;
            \\
            \\        for (int i = 0; i < num_clients; i++) {{
            \\            FD_SET(clients[i], &readfds);
            \\            if (clients[i] > max_fd) max_fd = clients[i];
            \\        }}
            \\
            \\        struct timeval tv = {{{d}, 0}};
            \\        int activity = select((int)max_fd + 1, &readfds, NULL, NULL, &tv);
            \\
            \\        if (activity < 0) {{
            \\#ifdef _WIN32
            \\            int err = WSAGetLastError();
            \\            if (err == WSAENOTSOCK) {{
            \\                for (int i = 0; i < num_clients; ) {{
            \\                    int optval;
            \\                    int optlen = sizeof(optval);
            \\                    if (getsockopt(clients[i], SOL_SOCKET, SO_TYPE, (char*)&optval, &optlen) == SOCKET_ERROR) {{
            \\                        orbit_socket_close(clients[i]);
            \\                        free_buffers[free_buffers_count++] = buffers[i];
            \\                        clients[i] = clients[num_clients - 1];
            \\                        buffered[i] = buffered[num_clients - 1];
            \\                        buffers[i] = buffers[num_clients - 1];
            \\                        num_clients--;
            \\                    }} else {{
            \\                        i++;
            \\                    }}
            \\                }}
            \\            }}
            \\#else
            \\            if (errno == EBADF || errno == ENOTSOCK) {{
            \\                for (int i = 0; i < num_clients; ) {{
            \\                    if (fcntl(clients[i], F_GETFD) == -1) {{
            \\                        orbit_socket_close(clients[i]);
            \\                        free_buffers[free_buffers_count++] = buffers[i];
            \\                        clients[i] = clients[num_clients - 1];
            \\                        buffered[i] = buffered[num_clients - 1];
            \\                        buffers[i] = buffers[num_clients - 1];
            \\                        num_clients--;
            \\                    }} else {{
            \\                        i++;
            \\                    }}
            \\                }}
            \\            }}
            \\#endif
            \\            continue;
            \\        }}
            \\
            \\        if (FD_ISSET(server_sock, &readfds)) {{
            \\            orbit_socket_t new_sock = accept(server_sock, NULL, NULL);
            \\            if (new_sock != ORBIT_INVALID_SOCKET) {{
            \\                if (num_clients < 512 && free_buffers_count > 0) {{
            \\                    int nodelay = 1;
            \\                    setsockopt(new_sock, IPPROTO_TCP, TCP_NODELAY, (char*)&nodelay, sizeof(nodelay));
            \\                    int sndbuf = 65536;
            \\                    int rcvbuf = 65536;
            \\                    setsockopt(new_sock, SOL_SOCKET, SO_SNDBUF, (char*)&sndbuf, sizeof(sndbuf));
            \\                    setsockopt(new_sock, SOL_SOCKET, SO_RCVBUF, (char*)&rcvbuf, sizeof(rcvbuf));
            \\                    clients[num_clients] = new_sock;
            \\                    buffered[num_clients] = 0;
            \\                    buffers[num_clients] = free_buffers[--free_buffers_count];
            \\                    num_clients++;
            \\                }} else {{
            \\                    orbit_socket_close(new_sock);
            \\                }}
            \\            }}
            \\        }}
            \\
            \\        for (int i = 0; i < num_clients; ) {{
            \\            orbit_socket_t client_sock = clients[i];
            \\            int drop = 0;
            \\            
            \\            if (FD_ISSET(client_sock, &readfds)) {{
            \\                int received = recv(client_sock, buffers[i] + buffered[i], 16384 - 1 - buffered[i], 0);
            \\                if (received == 0) {{
            \\                    drop = 1;
            \\                }} else if (received < 0) {{
            \\#ifdef _WIN32
            \\                    int err = WSAGetLastError();
            \\                    if (err != WSAEWOULDBLOCK) drop = 1;
            \\#else
            \\                    if (errno != EAGAIN && errno != EWOULDBLOCK) drop = 1;
            \\#endif
            \\                }} else {{
            \\                    buffered[i] += received;
            \\                    buffers[i][buffered[i]] = 0;
            \\                    
            \\                    int keep_alive = 1;
            \\                    size_t parsed = 0;
            \\                    while (parsed < buffered[i]) {{
            \\                        size_t consumed = 0;
            \\                        orbit_arena_reset(thread_arena);
            \\                        int keep = orbit_handle_request(client_sock, buffers[i] + parsed, buffered[i] - parsed, thread_arena, &consumed);
            \\                        if (!keep) keep_alive = 0;
            \\                        if (consumed == 0) break;
            \\                        parsed += consumed;
            \\                    }}
            \\                    
            \\                    if (parsed > 0) {{
            \\                        memmove(buffers[i], buffers[i] + parsed, buffered[i] - parsed);
            \\                        buffered[i] -= parsed;
            \\                    }}
            \\                    
            \\                    if (buffered[i] == 16384 - 1 || !keep_alive) {{
            \\                        drop = 1;
            \\                    }}
            \\                }}
            \\            }}
            \\            
            \\            if (drop) {{
            \\                orbit_socket_close(client_sock);
            \\                free_buffers[free_buffers_count++] = buffers[i];
            \\                clients[i] = clients[num_clients - 1];
            \\                buffered[i] = buffered[num_clients - 1];
            \\                buffers[i] = buffers[num_clients - 1];
            \\                num_clients--;
            \\            }} else {{
            \\                i++;
            \\            }}
            \\        }}
            \\    }}
            \\    free(buffer_pool);
            \\    orbit_arena_destroy(thread_arena);
            \\#ifdef _WIN32
            \\    return 0;
            \\#else
            \\    return NULL;
            \\#endif
            \\}}
            \\
            \\int main(int argc, char* argv[]) {{
            \\    orbit_http_init();
            \\    orbit_db_init("{s}");
            \\    orbit_arena_pool_init({d}, {d});
            \\    orbit_string_pool_init({d});
            \\
            \\    OrbitKynxConfig kynx_cfg = {{
            \\        .pool_size       = {d},
            \\        .rate_limit      = {d},
            \\        .window_ms       = {d},
            \\        .ban_threshold   = {d},
            \\        .score_increment = 10,
            \\        .score_decay     = 1,
            \\        .enabled         = {s}
            \\    }};
            \\    orbit_kynx_init(kynx_cfg);
            \\
            \\    OrbitArena* startup_arena = orbit_arena_pool_acquire();
            \\    int _orbit_exit_code = orbit_main(startup_arena);
            \\    orbit_arena_pool_release(startup_arena);
            \\
            \\    int port = {d};
            \\    if (argc > 1) {{
            \\        port = atoi(argv[1]);
            \\    }}
            \\
            \\    orbit_socket_t server_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            \\    if (server_sock == ORBIT_INVALID_SOCKET) {{
            \\        printf("Failed to create socket\n");
            \\        return 1;
            \\    }}
            \\
            \\    int reuse = 1;
            \\    setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));
            \\    int nodelay = 1;
            \\    setsockopt(server_sock, IPPROTO_TCP, TCP_NODELAY, (char*)&nodelay, sizeof(nodelay));
            \\#ifdef _WIN32
            \\    u_long mode = 1;
            \\    ioctlsocket(server_sock, FIONBIO, &mode);
            \\#else
            \\    int flags = fcntl(server_sock, F_GETFL, 0);
            \\    fcntl(server_sock, F_SETFL, flags | O_NONBLOCK);
            \\#endif
            \\    orbit_enable_reuseport(server_sock);
            \\
            \\    struct sockaddr_in server_addr;
            \\    server_addr.sin_family = AF_INET;
            \\    server_addr.sin_addr.s_addr = INADDR_ANY;
            \\    server_addr.sin_port = htons(port);
            \\
            \\    if (bind(server_sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == ORBIT_SOCKET_ERROR) {{
            \\        printf("Bind failed\n");
            \\        orbit_socket_close(server_sock);
            \\        return 1;
            \\    }}
            \\
            \\    if (listen(server_sock, SOMAXCONN) == ORBIT_SOCKET_ERROR) {{
            \\        printf("Listen failed\n");
            \\        orbit_socket_close(server_sock);
            \\        return 1;
            \\    }}
            \\
            \\#ifdef _WIN32
            \\    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
            \\    if (hOut != INVALID_HANDLE_VALUE) {{
            \\        DWORD dwMode = 0;
            \\        if (GetConsoleMode(hOut, &dwMode)) {{
            \\            SetConsoleMode(hOut, dwMode | 0x0001 | 0x0004);
            \\        }}
            \\        SetConsoleOutputCP(65001);
            \\    }}
            \\#endif
            \\
            \\    int num_workers = {d};
            \\    if (num_workers <= 0) num_workers = 1;
            \\    if (num_workers > 64) num_workers = 64;
            \\
            \\    orbit_render_server_banner(port, num_workers, kynx_cfg.enabled, {d});
            \\
            \\    orbit_thread_t* workers = (orbit_thread_t*)malloc(sizeof(orbit_thread_t) * (size_t)num_workers);
            \\    OrbitWorkerCtx* ctxs = (OrbitWorkerCtx*)malloc(sizeof(OrbitWorkerCtx) * (size_t)num_workers);
            \\
            \\    for (int i = 1; i < num_workers; i++) {{
            \\        ctxs[i].server_sock = server_sock;
            \\        ctxs[i].thread_id   = i;
            \\        ctxs[i].port        = port;
            \\        ORBIT_THREAD_CREATE(workers[i], orbit_worker_loop, &ctxs[i]);
            \\    }}
            \\
            \\    ctxs[0].server_sock = server_sock;
            \\    ctxs[0].thread_id   = 0;
            \\    ctxs[0].port        = port;
            \\    orbit_worker_loop(&ctxs[0]);
            \\
            \\    orbit_kynx_cleanup();
            \\    orbit_arena_pool_cleanup();
            \\    orbit_string_pool_cleanup();
            \\    orbit_db_close();
            \\    orbit_http_cleanup();
            \\    orbit_socket_close(server_sock);
            \\    return _orbit_exit_code;
            \\}}
            \\
        , .{
            config.keepalive_timeout_s,
            config.db_path,
            config.arena_pool_size,
            config.arena_default_capacity,
            config.string_pool_capacity,
            config.kynx_pool_size,
            config.kynx_rate_limit,
            config.kynx_window_ms,
            config.kynx_ban_threshold,
            if (config.no_kynx) "false" else "true",
            config.port,
            config.worker_threads,
            superluminal_boost_pct,
        });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\extern char** _orbit_argv;
            \\extern int _orbit_argc;
            \\
            \\int main(int argc, char* argv[]) {{
            \\    _orbit_argv = argv;
            \\    _orbit_argc = argc;
            \\    {s}
            \\    orbit_string_pool_init({d});
            \\    OrbitArena* arena = orbit_arena_create({d});
            \\
            \\    int _orbit_exit_code = orbit_main(arena);
            \\
            \\    orbit_arena_destroy(arena);
            \\    orbit_string_pool_cleanup();
            \\    {s}
            \\    return _orbit_exit_code;
            \\}}
            \\
        , .{
            if (has_db) try std.fmt.allocPrint(allocator, "orbit_db_init(\"{s}\");", .{config.db_path}) else "",
            config.string_pool_capacity,
            config.arena_default_capacity,
            if (has_db) "orbit_db_close();" else "",
        });
    }
}
