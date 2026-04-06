const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const StatementGenerator = @import("statement_gen.zig").StatementGenerator;

pub const RouteGenerator = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    source: []const u8,
    route_count: u32,
    
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), source: []const u8) RouteGenerator {
        return .{
            .allocator = allocator,
            .output = output,
            .source = source,
            .route_count = 0,
        };
    }
    
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
        _ = self;
        _ = method;
        _ = path;
        _ = func_name;
    }
    
    pub fn generateRouteDispatcher(self: *RouteGenerator) !void {
        try self.output.appendSlice(self.allocator,
            \\void orbit_handle_request(SOCKET client, char* buffer, OrbitArena* arena) {
            \\    OrbitRequest req = {0};
            \\    
            \\    char* method_end = strchr(buffer, ' ');
            \\    if (!method_end) return;
            \\    
            \\    size_t method_len = method_end - buffer;
            \\    if (method_len >= sizeof(req.method)) return;
            \\    
            \\    memcpy(req.method, buffer, method_len);
            \\    req.method[method_len] = 0;
            \\    
            \\    char* path_start = method_end + 1;
            \\    char* path_end = strchr(path_start, ' ');
            \\    if (!path_end) return;
            \\    
            \\    size_t path_len = path_end - path_start;
            \\    if (path_len >= sizeof(req.path)) return;
            \\    
            \\    memcpy(req.path, path_start, path_len);
            \\    req.path[path_len] = 0;
            \\    
            \\    OrbitResponse resp = orbit_response_text(404, "Not Found");
            \\    orbit_send_response(client, &resp);
            \\}
            \\
            \\
        );
    }
};
