const std = @import("std");
const AtlasConfig = @import("../atlas.zig").AtlasConfig;

/// Generates the #include for the Orbit runtime header.
/// Uses a relative path from the project root.
pub fn generateHeaders(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\#define ORBIT_CUSTOM_ROUTER
        \\#include "src/runtime/runtime.h"
        \\
        \\
    , .{});
}

/// Generates the main() function for the compiled binary.
/// All configuration is driven by AtlasConfig — no hardcoded values.
pub fn generateMainFunction(allocator: std.mem.Allocator, has_server: bool, config: AtlasConfig) ![]const u8 {
    if (has_server) {
        return try std.fmt.allocPrint(allocator,
            \\int main(void) {{
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
            \\    orbit_main(startup_arena);
            \\    orbit_arena_pool_release(startup_arena);
            \\
            \\    SOCKET server_sock = socket(AF_INET, SOCK_STREAM, 0);
            \\    if (server_sock == INVALID_SOCKET) {{
            \\        printf("Failed to create socket\n");
            \\        return 1;
            \\    }}
            \\
            \\    struct sockaddr_in server_addr;
            \\    server_addr.sin_family = AF_INET;
            \\    server_addr.sin_addr.s_addr = INADDR_ANY;
            \\    server_addr.sin_port = htons({d});
            \\
            \\    if (bind(server_sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == SOCKET_ERROR) {{
            \\        printf("Bind failed\n");
            \\        closesocket(server_sock);
            \\        return 1;
            \\    }}
            \\
            \\    if (listen(server_sock, 10) == SOCKET_ERROR) {{
            \\        printf("Listen failed\n");
            \\        closesocket(server_sock);
            \\        return 1;
            \\    }}
            \\
            \\    printf("Orbit listening on port %d\n", {d});
            \\
            \\    while (1) {{
            \\        SOCKET client_sock = accept(server_sock, NULL, NULL);
            \\        if (client_sock == INVALID_SOCKET) continue;
            \\
            \\        OrbitArena* arena = orbit_arena_pool_acquire();
            \\
            \\        char buffer[8192];
            \\        int received = recv(client_sock, buffer, sizeof(buffer) - 1, 0);
            \\        if (received > 0) {{
            \\            buffer[received] = 0;
            \\            orbit_handle_request(client_sock, buffer, arena);
            \\        }}
            \\
            \\        orbit_arena_pool_release(arena);
            \\        closesocket(client_sock);
            \\    }}
            \\
            \\    orbit_kynx_cleanup();
            \\    orbit_arena_pool_cleanup();
            \\    orbit_string_pool_cleanup();
            \\    orbit_db_close();
            \\    orbit_http_cleanup();
            \\    closesocket(server_sock);
            \\    return 0;
            \\}}
            \\
        , .{
            config.db_path,
            config.arena_pool_size,     config.arena_default_capacity,
            config.string_pool_capacity,
            config.kynx_pool_size,      config.kynx_rate_limit,
            config.kynx_window_ms,      config.kynx_ban_threshold,
            if (config.no_kynx) "false" else "true",
            config.port,
            config.port,
        });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\int main(void) {{
            \\    orbit_db_init("{s}");
            \\    orbit_string_pool_init({d});
            \\    OrbitArena* arena = orbit_arena_create({d});
            \\
            \\    orbit_main(arena);
            \\
            \\    orbit_arena_destroy(arena);
            \\    orbit_string_pool_cleanup();
            \\    orbit_db_close();
            \\    return 0;
            \\}}
            \\
        , .{
            config.db_path,
            config.string_pool_capacity,
            config.arena_default_capacity,
        });
    }
}
