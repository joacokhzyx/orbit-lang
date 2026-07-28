//! HTTP route handler code generator.
//!
//! `RouteGenerator` converts `route_decl` AST nodes into numbered C handler
//! functions (`orbit_route_N`) and emits the top-level
//! `orbit_handle_request` dispatcher that routes incoming HTTP requests.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const StatementGenerator = @import("statement_gen.zig").StatementGenerator;

const RouteEntry = struct {
    method: []const u8,
    path: []const u8,
    func_name: []const u8,
};

/// Generates one C handler function per route declaration and the central
/// HTTP request dispatcher.
pub const RouteGenerator = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    source: []const u8,
    route_count: u32,
    routes: std.ArrayListUnmanaged(RouteEntry),

    /// Initialise a `RouteGenerator` with a zero-based route counter.
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), source: []const u8) RouteGenerator {
        return .{
            .allocator = allocator,
            .output = output,
            .source = source,
            .route_count = 0,
            .routes = .empty,
        };
    }

    /// Emit a C handler function for the `route_decl` AST `node` and register
    /// the route mapping (HTTP method + path → handler name).
    pub fn generate(self: *RouteGenerator, node: *Node) !void {
        const route_data = node.data.route_decl;
        const method = route_data.method.getText(self.source);
        const path = route_data.path.getText(self.source);

        const func_name = try std.fmt.allocPrint(self.allocator, "orbit_route_{d}", .{self.route_count});
        self.route_count += 1;

        try self.output.appendSlice(self.allocator, "void ");
        try self.output.appendSlice(self.allocator, func_name);
        try self.output.appendSlice(self.allocator, "(SOCKET client, OrbitRequest* req, OrbitArena* arena) {\n");

        var stmt_gen = StatementGenerator.init(self.allocator, self.output, self.source);
        stmt_gen.indent_level = 1;

        if (route_data.body.tag == .block) {
            for (route_data.body.data.block.stmts) |stmt| {
                try stmt_gen.generate(stmt);
            }
        } else {
            try stmt_gen.generate(route_data.body);
        }

        try self.output.appendSlice(self.allocator, "}\n\n");

        try self.registerRoute(method, path, func_name);
    }

    fn registerRoute(self: *RouteGenerator, method: []const u8, path: []const u8, func_name: []const u8) !void {
        const inner_path = if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') path[1 .. path.len - 1] else path;
        try self.routes.append(self.allocator, .{
            .method = method,
            .path = try self.allocator.dupe(u8, inner_path),
            .func_name = try self.allocator.dupe(u8, func_name),
        });
    }

    /// Emit the `orbit_handle_request` C function that dispatches incoming
    /// HTTP requests to the registered route handlers.
    pub fn generateRouteDispatcher(self: *RouteGenerator) !void {
        try self.output.appendSlice(self.allocator,
            \\int orbit_handle_request(SOCKET client, char* buffer, size_t raw_len, OrbitArena* arena, size_t* out_consumed) {
            \\    if (out_consumed) *out_consumed = raw_len;
            \\    OrbitRequest req = {0};
            \\    
            \\    int keep_alive = 1;
            \\    if (strstr(buffer, "Connection: close") || strstr(buffer, "connection: close")) keep_alive = 0;
            \\    
            \\    char* method_end = strchr(buffer, ' ');
            \\    if (!method_end) return keep_alive;
            \\    
            \\    size_t method_len = method_end - buffer;
            \\    if (method_len >= sizeof(req.method)) return keep_alive;
            \\    
            \\    memcpy(req.method, buffer, method_len);
            \\    req.method[method_len] = 0;
            \\    
            \\    char* path_start = method_end + 1;
            \\    char* path_end = strchr(path_start, ' ');
            \\    if (!path_end) return keep_alive;
            \\    
            \\    size_t path_len = path_end - path_start;
            \\    if (path_len >= sizeof(req.path)) return keep_alive;
            \\    
            \\    memcpy(req.path, path_start, path_len);
            \\    req.path[path_len] = 0;
            \\    
        );

        for (self.routes.items, 0..) |route, i| {
            if (i == 0) {
                try self.output.print(self.allocator, "    if (strcmp(req.method, \"{s}\") == 0 && strcmp(req.path, \"{s}\") == 0) {{\n", .{ route.method, route.path });
            } else {
                try self.output.print(self.allocator, "    }} else if (strcmp(req.method, \"{s}\") == 0 && strcmp(req.path, \"{s}\") == 0) {{\n", .{ route.method, route.path });
            }
            try self.output.print(self.allocator, "        uint64_t _rhash = oracle_route_hash(\"{s}\", \"{s}\");\n", .{ route.method, route.path });
            try self.output.appendSlice(self.allocator, "        oracle_begin_session(arena, _rhash);\n");
            try self.output.print(self.allocator, "        {s}(client, &req, arena);\n", .{route.func_name});
            try self.output.appendSlice(self.allocator, "        oracle_end_session(arena);\n");
            try self.output.appendSlice(self.allocator, "        return keep_alive;\n");
        }
        try self.output.appendSlice(self.allocator, "    } else {\n");
        try self.output.appendSlice(self.allocator, "        OrbitResponse resp = orbit_response_text(404, \"Not Found\");\n");
        try self.output.appendSlice(self.allocator, "        orbit_send_response(client, &resp);\n");
        try self.output.appendSlice(self.allocator, "        return keep_alive;\n");
        try self.output.appendSlice(self.allocator, "    }\n");
        try self.output.appendSlice(self.allocator, "}\n\n");
    }
};
