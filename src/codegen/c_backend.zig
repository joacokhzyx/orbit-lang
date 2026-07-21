//! C code-generation backend for the Orbit compiler.
//!
//! Translates an `IRModule` (produced by `ir/builder.zig`) into a single C
//! translation unit that is compiled by the host C toolchain.  Handles type
//! emission (enums, unions, models), forward declarations, function bodies,
//! the HTTP request router, and the synthesised `main` entry-point.

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRModule = ir.IRModule;
const IRFunction = ir.IRFunction;
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IRType = ir.IRType;
const IRTypeDecl = ir.IRTypeDecl;
const IRModel = ir.IRModel;
const RuntimeLoader = @import("runtime_loader.zig");
const AtlasConfig = @import("../atlas.zig").AtlasConfig;
const superluminal_matcher = @import("../superluminal/pattern_matcher.zig");
const superluminal_emitter = @import("../superluminal/emitter.zig");
const superluminal_semantic = @import("../superluminal/semantic_enhancer.zig");
const superluminal_superopt = @import("../superluminal/superoptimizer.zig");
const superluminal_dualpath = @import("../superluminal/dual_path.zig");
const superluminal_synthesis = @import("../superluminal/synthesis.zig");
const superluminal_boost = @import("../superluminal/boost_display.zig");

pub const CBackend = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8),
    config: AtlasConfig,
    has_server_init: bool,
    call_args: std.ArrayListUnmanaged(IRValue),
    current_func: ?*const IRFunction = null,
    golden_mode: bool = false,
    handler_emitted: bool = false,

    /// Set of known functions that require OrbitArena* as first argument.
    /// Dynamically checked — not hardcoded per function name.
    arena_functions: std.StringHashMapUnmanaged(void),

    /// Model names registered during generation for type resolution.
    model_names: std.StringHashMapUnmanaged(void),

    /// Enum names registered during generation for type resolution.
    enum_names: std.StringHashMapUnmanaged(void),

    /// Union names registered during generation for type resolution.
    union_names: std.StringHashMapUnmanaged(void),

    /// Local variable types in the current function being generated.
    local_variable_types: std.StringHashMapUnmanaged(IRType),

    /// Superluminal boost metrics accumulated across all functions.
    boost_metrics: superluminal_boost.BoostMetrics = .{},

    // ─── Lifecycle ───────────────────────────────────────────────────────────

    /// Create a new `CBackend` with empty output buffers.
    /// `has_server_init` controls whether the generated `main` starts an HTTP server.
    pub fn init(allocator: std.mem.Allocator, config: AtlasConfig, has_server_init: bool) CBackend {
        return .{
            .allocator = allocator,
            .output = .empty,
            .config = config,
            .has_server_init = has_server_init,
            .call_args = .empty,
            .current_func = null,
            .arena_functions = .empty,
            .model_names = .empty,
            .enum_names = .empty,
            .union_names = .empty,
            .local_variable_types = .empty,
        };
    }

    /// Release all memory owned by this backend instance.
    pub fn deinit(self: *CBackend) void {
        self.output.deinit(self.allocator);
        self.call_args.deinit(self.allocator);
        self.arena_functions.deinit(self.allocator);
        self.model_names.deinit(self.allocator);
        self.enum_names.deinit(self.allocator);
        self.union_names.deinit(self.allocator);
        self.local_variable_types.deinit(self.allocator);
    }

    /// Register a runtime function that needs Arena* as first param.
    fn registerArenaFunction(self: *CBackend, name: []const u8) !void {
        try self.arena_functions.put(self.allocator, name, {});
    }

    fn routeHash(path: []const u8, method: []const u8) u64 {
        var h: u64 = 14695981039346656037;
        for (method) |c| { h = (h ^ @as(u64, c)) *% 1099511628211; }
        h = (h ^ @as(u64, ':')) *% 1099511628211;
        for (path) |c| { h = (h ^ @as(u64, c)) *% 1099511628211; }
        return h;
    }

    fn generateRouter(self: *CBackend, module: IRModule) !void {
        try self.output.appendSlice(self.allocator, "#ifdef ORBIT_WITH_NET\n");
        try self.output.appendSlice(self.allocator,
            \\static inline uint64_t orbit_route_hash(const char* method, const char* path) {
            \\    uint64_t h = 14695981039346656037ULL;
            \\    if (!method || !path) return 0;
            \\    while (*method) { h = (h ^ (unsigned char)*method++) * 1099511628211ULL; }
            \\    h = (h ^ ':') * 1099511628211ULL;
            \\    while (*path) { h = (h ^ (unsigned char)*path++) * 1099511628211ULL; }
            \\    return h;
            \\}
            \\
            \\static inline void orbit_log_request_fmt(const char* method, const char* path, int status, uint64_t start_rdtsc) {
            \\    uint64_t elapsed_cycles = orbit_rdtsc() - start_rdtsc;
            \\    double ms = (double)elapsed_cycles / 2500000.0;
            \\    if (ms < 0.05) ms = 0.1;
            \\
            \\    const char* method_str = (method && method[0]) ? method : "GET";
            \\    const char* path_str = (path && path[0]) ? path : "/";
            \\
            \\    const char* status_color = "\x1b[32m";
            \\    if (status >= 300 && status < 400) status_color = "\x1b[36m";
            \\    else if (status >= 400 && status < 500) status_color = "\x1b[33m";
            \\    else if (status >= 500) status_color = "\x1b[31m";
            \\
            \\    const char* status_text = "OK";
            \\    if (status == 201) status_text = "Created";
            \\    else if (status == 204) status_text = "No Content";
            \\    else if (status == 304) status_text = "Not Modified";
            \\    else if (status == 400) status_text = "Bad Request";
            \\    else if (status == 401) status_text = "Unauthorized";
            \\    else if (status == 403) status_text = "Forbidden";
            \\    else if (status == 404) status_text = "Not Found";
            \\    else if (status == 500) status_text = "Internal Error";
            \\    else if (status == 503) status_text = "Siege Mode Active";
            \\
            \\    printf("  \x1b[1;36m%-6s\x1b[0m \x1b[1;37m%-32s\x1b[0m %s%d %-18s\x1b[0m \x1b[2;90m%.1f ms\x1b[0m\n",
            \\        method_str, path_str, status_color, status, status_text, ms);
            \\}
            \\
            \\int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed) {
            \\    uint64_t start = orbit_rdtsc();
            \\    orbit_perf_start_request();
            \\
            \\    OrbitRequest* req = NULL;
            \\    size_t consumed = orbit_http_parse_request(arena, raw_request, raw_len, &req);
            \\    if (out_consumed) *out_consumed = consumed;
            \\    if (!req) return 1;
            \\
            \\    int keep_alive = 1;
            \\    if (strstr(raw_request, "Connection: close") || strstr(raw_request, "connection: close")) keep_alive = 0;
            \\
            \\    extern OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
            \\    extern void orbit_kynx_lease_destroy(OrbitKynxLease* lease);
            \\    OrbitKynxLease* lease = orbit_kynx_lease_create_for_route(req->path, req->method, arena);
            \\    if (lease && (lease->flags & 1)) {
            \\        OrbitResponse* res = orbit_response_create(arena, 503, "text/plain", "503 Siege Mode Active - Non-critical Route Blocked");
            \\        orbit_send_response(client_sock, res);
            \\        orbit_log_request_fmt(req->method, req->path, 503, start);
            \\        orbit_kynx_lease_destroy(lease);
            \\        orbit_perf_end_request(start);
            \\        return 0;
            \\    }
            \\        
            \\    if (req->path && strcmp(req->path, "/_pulse") == 0) {
            \\        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
            \\        orbit_send_response(client_sock, res);
            \\        orbit_log_request_fmt(req->method, req->path, 200, start);
            \\        if (lease) orbit_kynx_lease_destroy(lease);
            \\        orbit_perf_end_request(start);
            \\        return keep_alive;
            \\    }
            \\    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
            \\        orbit_string json = orbit_pulse_get_stats_json(arena);
            \\        OrbitResponse* res = orbit_response_json(arena, 200, json);
            \\        orbit_send_response(client_sock, res);
            \\        orbit_log_request_fmt(req->method, req->path, 200, start);
            \\        if (lease) orbit_kynx_lease_destroy(lease);
            \\        orbit_perf_end_request(start);
            \\        return keep_alive;
            \\    }
            \\
        );

        try self.output.appendSlice(self.allocator,
            \\    uint64_t route_key = orbit_route_hash(req->method, req->path);
            \\    switch (route_key) {
        );

        for (module.functions.items) |func| {
            if (func.route_info) |info| {
                const h = routeHash(info.path, info.method);
                const sanitized_name = try self.allocator.dupe(u8, func.name);
                defer self.allocator.free(sanitized_name);
                for (sanitized_name) |*c| {
                    if (!std.ascii.isAlphanumeric(c.*)) c.* = '_';
                }

                try self.output.print(self.allocator,
                    \\    case {d}: {{
                    \\        if (strcmp(req->path, "{s}") == 0 && strcmp(req->method, "{s}") == 0) {{
                    \\            OrbitResponse* res = {s}(arena, req);
                    \\            orbit_send_response(client_sock, res);
                    \\            orbit_log_request_fmt(req->method, req->path, (res ? res->status : 200), start);
                    \\            if (lease) orbit_kynx_lease_destroy(lease);
                    \\            orbit_perf_end_request(start);
                    \\            return keep_alive;
                    \\        }}
                    \\        break;
                    \\    }}
                    \\
                , .{ h, info.path, info.method, sanitized_name });
            }
        }

        try self.output.appendSlice(self.allocator,
            \\    default: {
            \\        OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
            \\        orbit_send_response(client_sock, res);
            \\        orbit_log_request_fmt(req->method, req->path, 404, start);
            \\        if (lease) orbit_kynx_lease_destroy(lease);
            \\        orbit_perf_end_request(start);
            \\        return keep_alive;
            \\    }
            \\    }
            \\}
            \\#endif
            \\
        );
    }

    // ─── Top-level generation ────────────────────────────────────────────────

    /// Generate a complete C translation unit from `module` and return the
    /// resulting source text as a newly-allocated slice (caller owns memory).
    pub fn generate(self: *CBackend, module: IRModule) ![]const u8 {
        var has_orbit_entry = false;
        for (module.functions.items) |func| {
            if (std.mem.eql(u8, func.name, "main") or std.mem.eql(u8, func.name, "orbit_main")) {
                has_orbit_entry = true;
                break;
            }
        }

        // Register known arena-requiring runtime functions
        try self.registerArenaFunction("orbit_file_read");
        try self.registerArenaFunction("orbit_file_list_dir");
        try self.registerArenaFunction("orbit_list_create");
        try self.registerArenaFunction("orbit_map_create");
        try self.registerArenaFunction("orbit_response_create");
        try self.registerArenaFunction("orbit_string_slice");
        try self.registerArenaFunction("orbit_string_split");
        try self.registerArenaFunction("orbit_string_replace");
        try self.registerArenaFunction("orbit_os_exec");
        try self.registerArenaFunction("orbit_os_env");
        try self.registerArenaFunction("orbit_os_argv");
        try self.registerArenaFunction("orbit_string_concat");
        try self.registerArenaFunction("orbit_int_to_string");
        try self.registerArenaFunction("orbit_float_to_string");
        try self.registerArenaFunction("orbit_bool_to_string");
        try self.registerArenaFunction("orbit_http_query_get");

        const headers = try RuntimeLoader.generateHeaders(self.allocator);
        try self.output.appendSlice(self.allocator, headers);
        try self.output.appendSlice(self.allocator, "\nOrbitArena* arena = NULL;\n");

        // Forward declare Models and prepopulate names
        for (module.models.items) |model| {
            try self.model_names.put(self.allocator, model.name, {});
            try self.output.print(self.allocator, "typedef struct {s} {s};\n", .{ model.name, model.name });
        }
        try self.output.appendSlice(self.allocator, "\n");

        // Generate Types (enums, unions, aliases)
        for (module.types.items) |t| {
            // Track enum and union names for type resolution
            if (t.kind == .enumeration) {
                try self.enum_names.put(self.allocator, t.name, {});
            } else if (t.kind == .union_type) {
                try self.union_names.put(self.allocator, t.name, {});
            }
            try self.generateType(t);
        }

        // Generate Models
        for (module.models.items) |model| {
            try self.generateModel(model);
        }

        // Forward declarations
        for (module.functions.items) |func| {
            if (func.is_extern) {
                continue;
            }
            try self.generateFunctionSignature(func);
            try self.output.appendSlice(self.allocator, ";\n");
        }

        try self.output.append(self.allocator, '\n');

        for (module.functions.items) |func| {
            if (func.is_extern) {
                continue;
            }
            try self.generateFunction(func);
        }

        try self.generateRouter(module);

        if (!has_orbit_entry) {
            try self.output.appendSlice(self.allocator,
                \\int orbit_main(OrbitArena* _init_arena) {
                \\    (void)_init_arena;
                \\    return 0;
                \\}
                \\
            );
        }

        var has_db = false;
        if (self.has_server_init) {
            has_db = true;
        } else {
            for (module.functions.items) |func| {
                for (func.instructions.items) |instr| {
                    switch (instr.opcode) {
                        .db_get, .db_set, .db_all, .db_where => {
                            has_db = true;
                            break;
                        },
                        else => {},
                    }
                }
                if (has_db) break;
            }
        }

        const main_func = try RuntimeLoader.generateMainFunction(self.allocator, self.has_server_init, has_db, self.config);
        try self.output.appendSlice(self.allocator, main_func);

        const pct = self.boost_metrics.boostPercent();
        if (pct >= 0.5) {
            superluminal_boost.printBoost(self.boost_metrics);
        }

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn generateFunctionSignature(self: *CBackend, func: IRFunction) !void {
        var func_name = try self.allocator.dupe(u8, func.name);
        defer self.allocator.free(func_name);

        if (std.mem.eql(u8, func_name, "main")) {
            self.allocator.free(func_name);
            func_name = try self.allocator.dupe(u8, "orbit_main");
        }

        // Sanitize route names: GET "/" -> route_GET_root
        for (func_name) |*c| {
            if (!std.ascii.isAlphanumeric(c.*)) {
                c.* = '_';
            }
        }

        // Determine return type from function context
        var ret_type: []const u8 = try self.mapTypeToC(func.return_type);
        if (std.mem.startsWith(u8, func_name, "route_")) {
            ret_type = "OrbitResponse*";
        } else if (std.mem.eql(u8, func_name, "orbit_main")) {
            ret_type = "int";
        }

        try self.output.appendSlice(self.allocator, ret_type);
        try self.output.append(self.allocator, ' ');
        try self.output.appendSlice(self.allocator, func_name);
        try self.output.append(self.allocator, '(');

        if (std.mem.eql(u8, func_name, "orbit_main")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* _init_arena");
        } else if (std.mem.startsWith(u8, func_name, "route_")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* arena, OrbitRequest* req");
        } else {
            if (func.params.len == 0) {
                try self.output.appendSlice(self.allocator, "void");
            } else {
                for (func.params, 0..) |param, i| {
                    if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                    const param_type = if (func.param_types.len > i) func.param_types[i] else .int;
                    try self.output.appendSlice(self.allocator, try self.mapTypeToC(param_type));
                    try self.output.append(self.allocator, ' ');
                    if (param_type == .model or param_type == .tagged_union or param_type == .pointer or param_type == .mut_pointer) {
                        try self.output.appendSlice(self.allocator, "__restrict ");
                    }
                    try self.output.appendSlice(self.allocator, param);
                }
            }
        }

        try self.output.append(self.allocator, ')');
    }

    fn generateFunction(self: *CBackend, func: IRFunction) !void {
        self.current_func = &func;

        self.local_variable_types.clearRetainingCapacity();
        for (func.instructions.items) |instr| {
            if (instr.opcode == .decl_var) {
                const var_name = instr.operand1.string;
                var var_type = self.getValueType(instr.operand2);
                if (instr.operand3 == .string) {
                    var_type = IRType.fromString(instr.operand3.string);
                }
                try self.local_variable_types.put(self.allocator, var_name, var_type);
            }
        }

        if (superluminal_dualpath.qualifies(func) and !std.mem.eql(u8, func.name, "main") and !std.mem.startsWith(u8, func.name, "route_")) {
            // Dual-path: emit golden + slow + wrapper with signal-based fallback
            const return_type_c = try self.mapTypeToC(func.return_type);

            // Emit signal handler once at file level
            if (!self.handler_emitted) {
                self.handler_emitted = true;
                try self.output.appendSlice(self.allocator,
                    "#include <signal.h>\n" ++
                    "#include <setjmp.h>\n" ++
                    "static thread_local jmp_buf sl_recovery;\n" ++
                    "static thread_local int sl_fallback = 0;\n" ++
                    "static void sl_handler(int sig) {\n" ++
                    "    (void)sig;\n" ++
                    "    sl_fallback = 1;\n" ++
                    "    longjmp(sl_recovery, 1);\n" ++
                    "}\n\n");
            }

            // 1. Golden variant (no safety checks)
            self.golden_mode = true;
            try self.output.appendSlice(self.allocator, "__attribute__((always_inline))\n    ");
            try self.generateSignatureWithSuffix(func, "_golden");
            try self.emitFunctionBody(func, .golden);
            self.golden_mode = false;

            // 2. Slow variant (full safety checks)
            try self.generateSignatureWithSuffix(func, "_slow");
            try self.emitFunctionBody(func, .normal);

            // 3. Wrapper: try golden, fall back to slow on SIGSEGV
            try self.output.appendSlice(self.allocator, return_type_c);
            try self.output.append(self.allocator, ' ');
            try self.output.appendSlice(self.allocator, func.name);
            try self.output.append(self.allocator, '(');
            try self.emitSignatureParams(func);
            try self.output.appendSlice(self.allocator, ") {\n");
            try self.output.print(self.allocator, "    void (*_sl_prev)(int) = signal(SIGSEGV, sl_handler);\n", .{});
            try self.output.appendSlice(self.allocator, "    if (setjmp(sl_recovery) == 0) {\n");
            try self.output.print(self.allocator, "        {s} _sl_result = {s}_golden(", .{ return_type_c, func.name });
            try self.emitCallArgs(func);
            try self.output.appendSlice(self.allocator, ");\n");
            try self.output.appendSlice(self.allocator, "        signal(SIGSEGV, _sl_prev);\n");
            try self.output.appendSlice(self.allocator, "        return _sl_result;\n");
            try self.output.appendSlice(self.allocator, "    } else {\n");
            try self.output.appendSlice(self.allocator, "        sl_fallback = 0;\n");
            try self.output.appendSlice(self.allocator, "        signal(SIGSEGV, _sl_prev);\n");
            try self.output.print(self.allocator, "        return {s}_slow(", .{func.name});
            try self.emitCallArgs(func);
            try self.output.appendSlice(self.allocator, ");\n");
            try self.output.appendSlice(self.allocator, "    }\n");
            try self.output.appendSlice(self.allocator, "}\n\n");
        } else {
            // Normal emission
            if (superluminal_semantic.shouldAnnotateFunction(func)) {
                try self.output.appendSlice(self.allocator, "__attribute__((always_inline))\n    ");
            }
            try self.generateFunctionSignature(func);
            try self.emitFunctionBody(func, .normal);
        }
    }

    fn generateSignatureWithSuffix(self: *CBackend, func: IRFunction, suffix: []const u8) !void {
        var func_name = try self.allocator.dupe(u8, func.name);
        defer self.allocator.free(func_name);

        if (std.mem.eql(u8, func_name, "main")) {
            self.allocator.free(func_name);
            func_name = try self.allocator.dupe(u8, "orbit_main");
        }

        for (func_name) |*c| {
            if (!std.ascii.isAlphanumeric(c.*)) {
                c.* = '_';
            }
        }

        var ret_type: []const u8 = try self.mapTypeToC(func.return_type);
        if (std.mem.startsWith(u8, func_name, "route_")) {
            ret_type = "OrbitResponse*";
        } else if (std.mem.eql(u8, func_name, "orbit_main")) {
            ret_type = "int";
        }

        try self.output.appendSlice(self.allocator, ret_type);
        try self.output.append(self.allocator, ' ');
        try self.output.appendSlice(self.allocator, func_name);
        try self.output.appendSlice(self.allocator, suffix);
        try self.output.append(self.allocator, '(');

        if (std.mem.eql(u8, func_name, "orbit_main")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* _init_arena");
        } else if (std.mem.startsWith(u8, func_name, "route_")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* arena, OrbitRequest* req");
        } else {
            if (func.params.len == 0) {
                try self.output.appendSlice(self.allocator, "void");
            } else {
                for (func.params, 0..) |param, i| {
                    if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                    const param_type = if (func.param_types.len > i) func.param_types[i] else .int;
                    try self.output.appendSlice(self.allocator, try self.mapTypeToC(param_type));
                    try self.output.append(self.allocator, ' ');
                    if (param_type == .model or param_type == .tagged_union or param_type == .pointer or param_type == .mut_pointer) {
                        try self.output.appendSlice(self.allocator, "__restrict ");
                    }
                    try self.output.appendSlice(self.allocator, param);
                }
            }
        }

        try self.output.append(self.allocator, ')');
    }

    fn emitSignatureParams(self: *CBackend, func: IRFunction) !void {
        if (std.mem.eql(u8, func.name, "main")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* _init_arena");
        } else if (std.mem.startsWith(u8, func.name, "route_")) {
            try self.output.appendSlice(self.allocator, "OrbitArena* arena, OrbitRequest* req");
        } else {
            if (func.params.len == 0) {
                try self.output.appendSlice(self.allocator, "void");
            } else {
                for (func.params, 0..) |param, i| {
                    if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                    const param_type = if (func.param_types.len > i) func.param_types[i] else .int;
                    try self.output.appendSlice(self.allocator, try self.mapTypeToC(param_type));
                    try self.output.append(self.allocator, ' ');
                    if (param_type == .model or param_type == .tagged_union or param_type == .pointer or param_type == .mut_pointer) {
                        try self.output.appendSlice(self.allocator, "__restrict ");
                    }
                    try self.output.appendSlice(self.allocator, param);
                }
            }
        }
    }

    fn emitCallArgs(self: *CBackend, func: IRFunction) !void {
        if (func.params.len == 0) return;
        for (func.params, 0..) |param, i| {
            if (i > 0) try self.output.appendSlice(self.allocator, ", ");
            try self.output.appendSlice(self.allocator, param);
        }
    }

    const EmitMode = enum { normal, golden };

    fn emitFunctionBody(self: *CBackend, func: IRFunction, mode: EmitMode) !void {
        if (mode == .golden) {
            self.golden_mode = true;
        } else {
            self.golden_mode = false;
        }
        self.current_func = &func;

        try self.output.appendSlice(self.allocator, " {\n");

        const is_main = std.mem.eql(u8, func.name, "main");
        const is_route = std.mem.startsWith(u8, func.name, "route_");

        if (is_main) {
            try self.output.appendSlice(self.allocator, "    arena = _init_arena;\n");
        }

        // Declare registers
        for (func.register_types.items, 0..) |reg_type, i| {
            if (reg_type == .void) continue;
            try self.output.appendSlice(self.allocator, "    ");
            try self.output.appendSlice(self.allocator, try self.mapTypeToC(reg_type));
            try self.output.print(self.allocator, " r_{d};\n", .{i});
        }

        // Declare local variables at top of function scope
        var var_iter = self.local_variable_types.iterator();
        while (var_iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            if (std.mem.eql(u8, var_name, "_")) continue;
            const var_type = entry.value_ptr.*;
            const c_type = try self.mapTypeToC(var_type);
            try self.output.print(self.allocator, "    {s} {s};\n", .{ c_type, var_name });
        }

        // Superluminal superoptimizer
        var superopt_instructions: ?[]const IRInstruction = null;
        defer if (superopt_instructions) |s| self.allocator.free(s);

        const superluminal_cost = @import("../superluminal/cost_model.zig");

        if (func.instructions.items.len <= 20) {
            var superopt = superluminal_superopt.Superoptimizer.init(self.allocator);
            superopt_instructions = superopt.optimize(func.instructions.items) catch null;
        }

        const emit_slice = if (superopt_instructions) |s| blk: {
            self.boost_metrics.superopt_improvements += 1;
            break :blk s;
        } else func.instructions.items;

        const base_cost = superluminal_cost.evaluateSlice(func.instructions.items);
        self.boost_metrics.total_instructions += func.instructions.items.len;
        self.boost_metrics.total_cost_before += base_cost.total();

        // Synthesis-based + pattern-based code emission
        var instr_i: usize = 0;
        var emit_cost = superluminal_cost.Cost{};
        while (instr_i < emit_slice.len) {
            if (superluminal_synthesis.findSynthesis(emit_slice, instr_i)) |m| {
                self.boost_metrics.synthesis_hits += 1;
                try self.emitSynthesis(emit_slice, m);
                emit_cost.alu += 1;
                instr_i += m.length;
            } else if (superluminal_matcher.findBest(emit_slice, instr_i)) |m| {
                self.boost_metrics.pattern_hits += 1;
                try superluminal_emitter.emitPattern(self, emit_slice, m);
                emit_cost.alu += m.cost_after.alu;
                emit_cost.mem_read += m.cost_after.mem_read;
                emit_cost.mem_write += m.cost_after.mem_write;
                emit_cost.branch += m.cost_after.branch;
                emit_cost.reg_assign += m.cost_after.reg_assign;
                emit_cost.call += m.cost_after.call;
                instr_i += m.length;
            } else {
                try self.generateInstruction(emit_slice[instr_i]);
                const c = superluminal_cost.evaluate(emit_slice[instr_i]);
                emit_cost.alu += c.alu;
                emit_cost.mem_read += c.mem_read;
                emit_cost.mem_write += c.mem_write;
                emit_cost.branch += c.branch;
                emit_cost.reg_assign += c.reg_assign;
                emit_cost.call += c.call;
                instr_i += 1;
            }
        }

        self.boost_metrics.total_cost_after += emit_cost.total();

        // Fallback return
        const has_trailing_ret = if (emit_slice.len > 0)
            emit_slice[emit_slice.len - 1].opcode == .ret else false;

        if (!has_trailing_ret) {
            if (is_main) {
                try self.output.appendSlice(self.allocator, "    return 0;\n");
            } else if (is_route) {
                try self.output.appendSlice(self.allocator, "    return orbit_response_create(arena, 500, \"text/plain\", \"Internal Server Error\");\n");
            } else if (func.return_type != .void) {
                switch (func.return_type) {
                    .int, .enumeration => try self.output.appendSlice(self.allocator, "    return 0;\n"),
                    .float => try self.output.appendSlice(self.allocator, "    return 0.0;\n"),
                    .bool => try self.output.appendSlice(self.allocator, "    return false;\n"),
                    .tagged_union => try self.output.appendSlice(self.allocator, "    return NULL;\n"),
                    else => try self.output.appendSlice(self.allocator, "    return NULL;\n"),
                }
            }
        }
        try self.output.appendSlice(self.allocator, "}\n\n");
    }

    fn emitSynthesis(self: *CBackend, instructions: []const IRInstruction, m: superluminal_synthesis.SynthesisMatch) !void {
        const info = superluminal_synthesis.getRuleInfo(m.rule_index);
        if (std.mem.eql(u8, info.name, "mul2_shl1")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            var shift: u6 = 0;
            var val = i.operand1;
            if (i.operand1 == .int) {
                shift = @intCast(@ctz(@as(i64, i.operand1.int)));
                val = i.operand2;
            } else if (i.operand2 == .int) {
                shift = @intCast(@ctz(@as(i64, i.operand2.int)));
                val = i.operand1;
            }
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(val);
            try self.output.print(self.allocator, " << {d};\n", .{shift});
        } else if (std.mem.eql(u8, info.name, "div2_shr1")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            const shift = @as(u6, @intCast(@ctz(@as(i64, i.operand2.int))));
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(i.operand1);
            try self.output.print(self.allocator, " >> {d};\n", .{shift});
        } else if (std.mem.eql(u8, info.name, "mod_pow2_and")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            const mask = i.operand2.int - 1;
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(i.operand1);
            try self.output.print(self.allocator, " & {d};\n", .{mask});
        } else if (std.mem.eql(u8, info.name, "double_neg") or std.mem.eql(u8, info.name, "not_not")) {
            const i = instructions[m.start + 1];
            const d = i.dest.?;
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(instructions[m.start].operand1);
            try self.output.appendSlice(self.allocator, ";\n");
        } else if (std.mem.eql(u8, info.name, "add_zero") or std.mem.eql(u8, info.name, "bool_and_true")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            const val = if (isIntConst(i.operand1, 0) or isIntConst(i.operand1, 1)) i.operand2 else i.operand1;
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(val);
            try self.output.appendSlice(self.allocator, ";\n");
        } else if (std.mem.eql(u8, info.name, "bool_or_false")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            const val = if (isIntConst(i.operand1, 0)) i.operand2 else i.operand1;
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(val);
            try self.output.appendSlice(self.allocator, ";\n");
        } else if (std.mem.eql(u8, info.name, "mul_one")) {
            const i = instructions[m.start];
            const d = i.dest.?;
            const val = if (isIntConst(i.operand1, 1)) i.operand2 else i.operand1;
            try self.output.print(self.allocator, "r_{d} = ", .{d});
            try self.generateValue(val);
            try self.output.appendSlice(self.allocator, ";\n");
        } else if (std.mem.eql(u8, info.name, "mul_zero")) {
            const d = instructions[m.start].dest.?;
            try self.output.print(self.allocator, "r_{d} = 0;\n", .{d});
        } else if (std.mem.eql(u8, info.name, "sub_self")) {
            const d = instructions[m.start].dest.?;
            try self.output.print(self.allocator, "r_{d} = 0;\n", .{d});
        } else if (std.mem.eql(u8, info.name, "increment")) {
            const store = instructions[m.start + 1];
            try self.output.print(self.allocator, "++{s};\n", .{store.operand1.string});
        } else if (std.mem.eql(u8, info.name, "decrement")) {
            const store = instructions[m.start + 1];
            try self.output.print(self.allocator, "--{s};\n", .{store.operand1.string});
        } else if (std.mem.eql(u8, info.name, "copy_self")) {
            // r_x = r_x — no-op
        } else {
            // Fallback: emit individual instructions
            var j: usize = 0;
            while (j < m.length) : (j += 1) {
                try self.generateInstruction(instructions[m.start + j]);
            }
        }
    }

    fn isIntConst(val: IRValue, c: i64) bool {
        return val == .int and val.int == c;
    }

    pub fn generateInstruction(self: *CBackend, instr: IRInstruction) !void {
        if (instr.opcode != .arg) {
            try self.output.appendSlice(self.allocator, "    ");
        }

        switch (instr.opcode) {
            .load_const => {},
            .copy => {
                if (instr.dest) |d| {
                    try self.output.print(self.allocator, "r_{d} = ", .{d});
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .load_var => {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.output.appendSlice(self.allocator, instr.operand1.string);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .load_field => {
                if (!self.golden_mode and (self.getValueType(instr.operand1) == .model or self.getValueType(instr.operand1) == .tagged_union)) {
                    try self.output.appendSlice(self.allocator, "__builtin_assume(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, " != (void*)0);\n    ");
                }
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                const obj_type = self.getValueType(instr.operand1);
                if (obj_type == .model or obj_type == .unknown or obj_type == .int) {
                    try self.output.appendSlice(self.allocator, "->");
                } else {
                    try self.output.append(self.allocator, '.');
                }
                try self.output.appendSlice(self.allocator, instr.operand2.string);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .store_var => {
                if (std.mem.eql(u8, instr.operand1.string, "_")) {
                    try self.output.appendSlice(self.allocator, "(void)");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ";\n");
                } else {
                    try self.output.appendSlice(self.allocator, instr.operand1.string);
                    try self.output.appendSlice(self.allocator, " = ");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .decl_var => {
                if (std.mem.eql(u8, instr.operand1.string, "_")) {
                    try self.output.appendSlice(self.allocator, "(void)");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ";\n");
                } else {
                    try self.output.appendSlice(self.allocator, instr.operand1.string);
                    try self.output.appendSlice(self.allocator, " = ");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .add => try self.generateBinaryOp(instr, " + "),
            .sub => try self.generateBinaryOp(instr, " - "),
            .mul => try self.generateBinaryOp(instr, " * "),
            .div => try self.generateBinaryOp(instr, " / "),
            .mod => try self.generateBinaryOp(instr, " % "),
            .eq => try self.generateBinaryOp(instr, " == "),
            .ne => try self.generateBinaryOp(instr, " != "),
            .lt => try self.generateBinaryOp(instr, " < "),
            .le => try self.generateBinaryOp(instr, " <= "),
            .gt => try self.generateBinaryOp(instr, " > "),
            .ge => try self.generateBinaryOp(instr, " >= "),
            .and_op => try self.generateBinaryOp(instr, " && "),
            .or_op => try self.generateBinaryOp(instr, " || "),
            .neg => {
                if (instr.dest) |d| {
                    try self.output.print(self.allocator, "r_{d} = -", .{d});
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .not_op => {
                if (instr.dest) |d| {
                    try self.output.print(self.allocator, "r_{d} = !", .{d});
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .arg => {
                try self.call_args.append(self.allocator, instr.operand1);
            },
            .begin_block => {
                try self.output.appendSlice(self.allocator, "{\n");
            },
            .end_block => {
                try self.output.appendSlice(self.allocator, "}\n");
            },
            .call => {
                const func_name = instr.operand1.string;

                if (std.mem.eql(u8, func_name, "print") and self.call_args.items.len == 1) {
                    const arg = self.call_args.items[0];
                    const arg_type = self.getValueType(arg);

                    const fmt = switch (arg_type) {
                        .int => "%d\\n",
                        .float => "%f\\n",
                        .string => "%s\\n",
                        .bool => "%s\\n",
                        else => "%s\\n",
                    };

                    try self.output.print(self.allocator, "print(\"{s}\", ", .{fmt});
                    if (arg_type == .bool) {
                        try self.generateValue(arg);
                        try self.output.appendSlice(self.allocator, " ? \"true\" : \"false\"");
                    } else if (arg_type != .int and arg_type != .float and arg_type != .string) {
                        try self.output.appendSlice(self.allocator, "(orbit_string)(");
                        try self.generateValue(arg);
                        try self.output.appendSlice(self.allocator, ")");
                    } else {
                        try self.generateValue(arg);
                    }
                    try self.output.appendSlice(self.allocator, ");\n");
                    self.call_args.clearRetainingCapacity();
                    return;
                }

                if (instr.dest) |d| {
                    const reg_type = if (self.current_func) |f| f.register_types.items[d] else .unknown;
                    if (reg_type != .void) {
                        try self.output.print(self.allocator, "r_{d} = ", .{d});
                    }
                }

                var first = true;
                // If this function requires an Arena, inject it as first arg
                const final_func_name = try self.allocator.dupe(u8, func_name);
                defer self.allocator.free(final_func_name);
                for (final_func_name) |*c| {
                    if (!std.ascii.isAlphanumeric(c.*)) c.* = '_';
                }

                try self.output.appendSlice(self.allocator, final_func_name);
                try self.output.append(self.allocator, '(');

                if (self.arena_functions.contains(func_name) or std.mem.startsWith(u8, func_name, "orbit_response_")) {
                    try self.output.appendSlice(self.allocator, "arena");
                    first = false;
                }

                for (self.call_args.items) |arg| {
                    if (!first) try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(arg);
                    first = false;
                }
                try self.output.appendSlice(self.allocator, ");\n");
                self.call_args.clearRetainingCapacity();
            },
            .ret => {
                if (instr.operand1 == .none) {
                    if (std.mem.eql(u8, self.current_func.?.name, "main")) {
                        try self.output.appendSlice(self.allocator, "return 0;\n");
                    } else if (self.current_func.?.return_type == .void) {
                        try self.output.appendSlice(self.allocator, "return;\n");
                    } else {
                        switch (self.current_func.?.return_type) {
                            .int, .enumeration => try self.output.appendSlice(self.allocator, "return 0;\n"),
                            .float => try self.output.appendSlice(self.allocator, "return 0.0;\n"),
                            .bool => try self.output.appendSlice(self.allocator, "return false;\n"),
                            else => try self.output.appendSlice(self.allocator, "return NULL;\n"),
                        }
                    }
                } else {
                    try self.output.appendSlice(self.allocator, "return ");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ";\n");
                }
            },
            .jump => {
                try self.output.appendSlice(self.allocator, "goto ");
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .jump_if_false => {
                try self.output.appendSlice(self.allocator, "if (__builtin_expect(");
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", 0)) goto ");
                try self.generateValue(instr.operand2);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .label => {
                self.output.items.len -= 4;
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ":;\n");
            },
            .store_field => {
                if (!self.golden_mode and (self.getValueType(instr.operand1) == .model or self.getValueType(instr.operand1) == .tagged_union)) {
                    try self.output.appendSlice(self.allocator, "__builtin_assume(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, " != (void*)0);\n    ");
                }
                try self.generateValue(instr.operand1);
                const obj_type = self.getValueType(instr.operand1);
                if (obj_type == .model or obj_type == .unknown or obj_type == .int) {
                    try self.output.print(self.allocator, "->{s} = ", .{instr.operand2.string});
                } else {
                    try self.output.print(self.allocator, ".{s} = ", .{instr.operand2.string});
                }
                try self.generateValue(instr.operand3);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            // ── Phase 2: Collection opcodes ─────────────────────────────
            .list_create => {
                try self.output.print(self.allocator, "{{ OrbitResult _lr = orbit_list_create(arena, {s}, ", .{
                    if (instr.operand1 == .int and instr.operand1.int == 4) "sizeof(orbit_int)" else "sizeof(void*)",
                });
                try self.generateValue(instr.operand2);
                try self.output.print(self.allocator, "); r_{d} = _lr.ok ? (OrbitList*)_lr.value : NULL; }}\n", .{instr.dest.?});
            },
            .list_push => {
                try self.output.appendSlice(self.allocator, "orbit_list_push(");
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", ");
                switch (instr.operand2) {
                    .int => |v| try self.output.print(self.allocator, "&(orbit_int){{{d}}}", .{v}),
                    .float => |v| try self.output.print(self.allocator, "&(orbit_float){{{d}}}", .{v}),
                    .string => |v| try self.output.print(self.allocator, "&(orbit_string){{\"{s}\"}}", .{v}),
                    .bool => |v| try self.output.print(self.allocator, "&(orbit_bool){{{s}}}", .{if (v) "true" else "false"}),
                    else => {
                        if (instr.operand2 == .register) {
                            try self.output.appendSlice(self.allocator, "&");
                            try self.generateValue(instr.operand2);
                        } else {
                            try self.generateValue(instr.operand2);
                        }
                    },
                }
                try self.output.appendSlice(self.allocator, ");\n");
            },
            .list_get => {
                if (self.golden_mode) {
                    try self.output.print(self.allocator, "r_{d} = ((", .{instr.dest.?});
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ")->data)[");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, "];\n");
                } else {
                    try self.output.appendSlice(self.allocator, "{ OrbitResult _lr = orbit_list_get(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(instr.operand2);
                    try self.output.print(self.allocator, "); r_{d} = ", .{instr.dest.?});
                    const dest_type = if (self.current_func) |f| f.register_types.items[instr.dest.?] else .unknown;
                    switch (dest_type) {
                        .int => try self.output.appendSlice(self.allocator, "_lr.ok ? *(orbit_int*)_lr.value : 0; }\n"),
                        .float => try self.output.appendSlice(self.allocator, "_lr.ok ? *(orbit_float*)_lr.value : 0.0; }\n"),
                        .string => try self.output.appendSlice(self.allocator, "_lr.ok ? *(orbit_string*)_lr.value : NULL; }\n"),
                        .bool => try self.output.appendSlice(self.allocator, "_lr.ok ? *(orbit_bool*)_lr.value : false; }\n"),
                        .tagged_union => |name| try self.output.print(self.allocator, "_lr.ok ? *({s}**)_lr.value : NULL; }}\n", .{name}),
                        else => try self.output.appendSlice(self.allocator, "_lr.ok ? *(void**)_lr.value : NULL; }\n"),
                    }
                }
            },
            .list_len => {
                try self.output.print(self.allocator, "r_{d} = (orbit_int)orbit_list_len(", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ");\n");
            },
            .map_create => {
                try self.output.print(self.allocator, "{{ OrbitResult _mr = orbit_map_create(arena, {s}); r_{d} = _mr.ok ? (OrbitMap*)_mr.value : NULL; }}\n", .{
                    if (instr.operand1 == .int and instr.operand1.int == 4) "sizeof(orbit_int)" else "sizeof(void*)",
                    instr.dest.?,
                });
            },
            .map_set => {
                if (self.golden_mode) {
                    try self.output.appendSlice(self.allocator, "{ *(void**)");
                    try self.output.appendSlice(self.allocator, "orbit_map_get_raw(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ") = ");
                    if (instr.operand3 == .register) {
                        try self.generateValue(instr.operand3);
                    } else {
                        try self.output.appendSlice(self.allocator, "NULL /* const map_set not supported in golden */");
                    }
                    try self.output.appendSlice(self.allocator, "; }\n");
                } else {
                    try self.output.appendSlice(self.allocator, "orbit_map_set(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ", ");
                    switch (instr.operand3) {
                        .int => |v| try self.output.print(self.allocator, "&(orbit_int){{{d}}}", .{v}),
                        .float => |v| try self.output.print(self.allocator, "&(orbit_float){{{d}}}", .{v}),
                        .string => |v| try self.output.print(self.allocator, "&(orbit_string){{\"{s}\"}}", .{v}),
                        .bool => |v| try self.output.print(self.allocator, "&(orbit_bool){{{s}}}", .{if (v) "true" else "false"}),
                        else => {
                            if (instr.operand3 == .register) {
                                try self.output.appendSlice(self.allocator, "&");
                                try self.generateValue(instr.operand3);
                            } else {
                                try self.output.appendSlice(self.allocator, "NULL /* unsupported operand */");
                            }
                        },
                    }
                    try self.output.appendSlice(self.allocator, ");\n");
                }
            },
            .map_get => {
                if (self.golden_mode) {
                    try self.output.print(self.allocator, "r_{d} = *(void**)orbit_map_get_raw(", .{instr.dest.?});
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(instr.operand2);
                    try self.output.appendSlice(self.allocator, ");\n");
                } else {
                    try self.output.appendSlice(self.allocator, "{ OrbitResult _mr = orbit_map_get(");
                    try self.generateValue(instr.operand1);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.generateValue(instr.operand2);
                    try self.output.print(self.allocator, "); r_{d} = ", .{instr.dest.?});
                    const dest_type = if (self.current_func) |f| f.register_types.items[instr.dest.?] else .unknown;
                    if (dest_type == .int) {
                        try self.output.appendSlice(self.allocator, "_mr.ok ? *(orbit_int*)_mr.value : 0; }\n");
                    } else if (dest_type == .float) {
                        try self.output.appendSlice(self.allocator, "_mr.ok ? *(orbit_float*)_mr.value : 0.0; }\n");
                    } else if (dest_type == .string) {
                        try self.output.appendSlice(self.allocator, "_mr.ok ? *(orbit_string*)_mr.value : NULL; }\n");
                    } else if (dest_type == .bool) {
                        try self.output.appendSlice(self.allocator, "_mr.ok ? *(orbit_bool*)_mr.value : false; }\n");
                    } else {
                        try self.output.appendSlice(self.allocator, "_mr.ok ? *(void**)_mr.value : NULL; }\n");
                    }
                }
            },
            .map_has => {
                try self.output.print(self.allocator, "r_{d} = orbit_map_has(", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", ");
                try self.generateValue(instr.operand2);
                try self.output.appendSlice(self.allocator, ");\n");
            },
            // ── Phase 2: Result opcodes ──────────────────────────────────
            .result_ok => {
                try self.output.print(self.allocator, "r_{d} = orbit_result_ok(", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ");\n");
            },
            .result_err => {
                try self.output.print(self.allocator, "r_{d} = orbit_result_err(", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", ");
                try self.generateValue(instr.operand2);
                try self.output.appendSlice(self.allocator, ");\n");
            },
            .result_is_ok => {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ".ok;\n");
            },
            .result_unwrap => {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ".value;\n");
            },
            // ── Phase 2: Union opcodes ───────────────────────────────────
            .union_create => {
                const union_name = if (self.current_func) |f| switch (f.register_types.items[instr.dest.?]) {
                    .tagged_union => |name| name,
                    else => instr.operand1.string,
                } else instr.operand1.string;

                try self.output.print(self.allocator, "{{ {s}* _u = orbit_alloc(arena, sizeof({s})); _u->tag = {s}; ", .{ union_name, union_name, instr.operand1.string });

                // Logic to set the correct data variant if we knew the field name
                // For now, Orbit Unions use a generic 'data' pointer or the first variant for simplistic init
                try self.output.appendSlice(self.allocator, "_u->data.data = ");
                try self.generateValue(instr.operand2);
                try self.output.print(self.allocator, "; r_{d} = _u; }}\n", .{instr.dest.?});
            },
            .union_get_tag => {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, "->tag;\n");
            },
            .union_get_data => {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, "->data.data;\n");
            },
            else => {},
        }
    }

    // ─── Instruction helpers ─────────────────────────────────────────────────

    /// Emit a binary arithmetic/comparison instruction: `r_D = op1 OP op2;`.
    /// Handles string concatenation via `orbit_string_concat` and string
    /// equality via `strcmp` automatically.
    fn generateBinaryOp(self: *CBackend, instr: IRInstruction, op: []const u8) !void {
        const type1 = self.getValueType(instr.operand1);
        const type2 = self.getValueType(instr.operand2);
        const dest_type = if (self.current_func) |f| f.register_types.items[instr.dest.?] else .unknown;

        if (std.mem.eql(u8, op, " + ") and (type1 == .string or type2 == .string or dest_type == .string)) {
            try self.output.print(self.allocator, "r_{d} = orbit_string_concat(arena, ", .{instr.dest.?});
            try self.generateStringConcatOperand(instr.operand1, type1);
            try self.output.appendSlice(self.allocator, ", ");
            try self.generateStringConcatOperand(instr.operand2, type2);
            try self.output.appendSlice(self.allocator, ");\n");
            return;
        }

        if (type1 == .string or type2 == .string) {
            if (std.mem.eql(u8, op, " == ")) {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.output.appendSlice(self.allocator, "strcmp(");
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", ");
                try self.generateValue(instr.operand2);
                try self.output.appendSlice(self.allocator, ") == 0;\n");
                return;
            } else if (std.mem.eql(u8, op, " != ")) {
                try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
                try self.output.appendSlice(self.allocator, "strcmp(");
                try self.generateValue(instr.operand1);
                try self.output.appendSlice(self.allocator, ", ");
                try self.generateValue(instr.operand2);
                try self.output.appendSlice(self.allocator, ") != 0;\n");
                return;
            }
        }

        try self.output.print(self.allocator, "r_{d} = ", .{instr.dest.?});
        try self.generateValue(instr.operand1);
        try self.output.appendSlice(self.allocator, op);
        try self.generateValue(instr.operand2);
        try self.output.appendSlice(self.allocator, ";\n");
    }

    fn generateStringConcatOperand(self: *CBackend, val: IRValue, t: IRType) !void {
        switch (t) {
            .int => {
                try self.output.appendSlice(self.allocator, "orbit_int_to_string(arena, ");
                try self.generateValue(val);
                try self.output.appendSlice(self.allocator, ")");
            },
            .float => {
                try self.output.appendSlice(self.allocator, "orbit_float_to_string(arena, ");
                try self.generateValue(val);
                try self.output.appendSlice(self.allocator, ")");
            },
            .bool => {
                try self.output.appendSlice(self.allocator, "orbit_bool_to_string(arena, ");
                try self.generateValue(val);
                try self.output.appendSlice(self.allocator, ")");
            },
            else => {
                try self.generateValue(val);
            },
        }
    }

    pub fn getValueType(self: *CBackend, val: IRValue) IRType {
        return switch (val) {
            .int => .int,
            .float => .float,
            .string => .string,
            .symbol => |s| blk: {
                if (self.local_variable_types.get(s)) |t| break :blk t;
                if (self.current_func) |f| {
                    for (f.params, f.param_types) |p_name, p_type| {
                        if (std.mem.eql(u8, p_name, s)) break :blk p_type;
                    }
                }
                if (self.model_names.contains(s)) break :blk .{ .model = s };
                break :blk .int;
            },
            .bool => .bool,
            .register => |r| if (self.current_func) |f| f.register_types.items[r] else .unknown,
            else => .unknown,
        };
    }

    pub fn generateValue(self: *CBackend, val: IRValue) !void {
        switch (val) {
            .int => |v| try self.output.print(self.allocator, "{d}", .{v}),
            .float => |v| try self.output.print(self.allocator, "{d}", .{v}),
            .string => |v| try self.output.print(self.allocator, "\"{s}\"", .{v}),
            .symbol => |v| try self.output.appendSlice(self.allocator, v),
            .bool => |v| try self.output.appendSlice(self.allocator, if (v) "true" else "false"),
            .register => |r| try self.output.print(self.allocator, "r_{d}", .{r}),
            .label => |l| try self.output.print(self.allocator, "label_{d}", .{l}),
            .none => {},
        }
    }

    fn mapTypeToC(self: *CBackend, type_val: IRType) ![]const u8 {
        return switch (type_val) {
            .int => "orbit_int",
            .float => "orbit_float",
            .string => "orbit_string",
            .bool => "orbit_bool",
            .void => "void",
            .response => "OrbitResponse*",
            .model => |m| try std.fmt.allocPrint(self.allocator, "{s}*", .{m}),
            .enumeration => |e| e,
            // Phase 2 types
            .list => "OrbitList*",
            .map => "OrbitMap*",
            .result => "OrbitResult",
            .option => "OrbitOption",
            .tagged_union => |name| try std.fmt.allocPrint(self.allocator, "{s}*", .{name}),
            .trait_obj => "OrbitInterface",
            .slice => "OrbitSlice",
            .unknown => "void*",
            // Sized integers and pointers
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .usize => "uintptr_t",
            .isize => "intptr_t",
            .byte => "uint8_t",
            .pointer => |inner| if (inner) |in| try std.fmt.allocPrint(self.allocator, "{s}*", .{try self.mapTypeToC(in.*)}) else "void*",
            .mut_pointer => |inner| if (inner) |in| try std.fmt.allocPrint(self.allocator, "{s}*", .{try self.mapTypeToC(in.*)}) else "void*",
        };
    }

    /// Map an Orbit field type name to its C equivalent.
    fn mapFieldTypeToC(self: *CBackend, orbit_type: []const u8) []const u8 {
        if (std.mem.eql(u8, orbit_type, "i8")) return "int8_t";
        if (std.mem.eql(u8, orbit_type, "i16")) return "int16_t";
        if (std.mem.eql(u8, orbit_type, "i32")) return "int32_t";
        if (std.mem.eql(u8, orbit_type, "i64")) return "int64_t";
        if (std.mem.eql(u8, orbit_type, "u8")) return "uint8_t";
        if (std.mem.eql(u8, orbit_type, "u16")) return "uint16_t";
        if (std.mem.eql(u8, orbit_type, "u32")) return "uint32_t";
        if (std.mem.eql(u8, orbit_type, "u64")) return "uint64_t";
        if (std.mem.eql(u8, orbit_type, "usize")) return "uintptr_t";
        if (std.mem.eql(u8, orbit_type, "isize")) return "intptr_t";
        if (std.mem.eql(u8, orbit_type, "byte")) return "uint8_t";
        if (std.mem.eql(u8, orbit_type, "pointer") or std.mem.eql(u8, orbit_type, "ptr")) return "void*";
        if (std.mem.eql(u8, orbit_type, "mut_pointer") or std.mem.eql(u8, orbit_type, "mut_ptr")) return "void*";

        if (std.mem.eql(u8, orbit_type, "int")) return "orbit_int";
        if (std.mem.eql(u8, orbit_type, "float")) return "orbit_float";
        if (std.mem.eql(u8, orbit_type, "string")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "bool")) return "orbit_bool";
        if (std.mem.eql(u8, orbit_type, "decimal")) return "orbit_decimal";
        if (std.mem.eql(u8, orbit_type, "response")) return "orbit_string";
        // Validated string types all map to orbit_string
        if (std.mem.eql(u8, orbit_type, "Email")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "URL")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "UUID")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "Phone")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "IP")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "Date")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "Time")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "DateTime")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "Timestamp")) return "orbit_string";

        if (self.enum_names.contains(orbit_type)) return orbit_type; // by-value
        if (self.model_names.contains(orbit_type) or self.union_names.contains(orbit_type)) {
            return std.fmt.allocPrint(self.allocator, "{s}*", .{orbit_type}) catch "void*";
        }

        // If it starts with uppercase, it's probably a model/enum type — use as-is
        if (orbit_type.len > 0 and std.ascii.isUpper(orbit_type[0])) return orbit_type;
        return "void*";
    }

    fn generateType(self: *CBackend, t: IRTypeDecl) !void {
        switch (t.kind) {
            .enumeration => {
                try self.output.print(self.allocator, "typedef enum {{\n", .{});
                for (t.variants, 0..) |variant, i| {
                    try self.output.print(self.allocator, "    {s}_TAG_{s} = {d}", .{ t.name, variant, i });
                    if (i < t.variants.len - 1) try self.output.appendSlice(self.allocator, ",");
                    try self.output.append(self.allocator, '\n');
                }
                try self.output.print(self.allocator, "}} {s};\n", .{t.name});
                // Phase 2: Emit tag count constant
                try self.output.print(self.allocator, "#define {s}_COUNT {d}\n\n", .{ t.name, t.variants.len });
            },
            .union_type => {
                // Phase 2: Emit tagged enum for discriminant
                try self.output.print(self.allocator, "typedef enum {{\n", .{});
                for (t.variants, 0..) |variant, i| {
                    try self.output.print(self.allocator, "    {s}_TAG_{s} = {d}", .{ t.name, variant, i });
                    if (i < t.variants.len - 1) try self.output.appendSlice(self.allocator, ",");
                    try self.output.append(self.allocator, '\n');
                }
                try self.output.print(self.allocator, "}} {s}_Tag;\n\n", .{t.name});

                // Emit the tagged union struct
                try self.output.print(self.allocator, "typedef struct {s} {{\n", .{t.name});
                try self.output.print(self.allocator, "    {s}_Tag tag;\n", .{t.name});
                try self.output.print(self.allocator, "    union {{\n", .{});
                try self.output.print(self.allocator, "        void* data;\n", .{});
                for (t.rich_variants) |rv| {
                    if (rv.payload_type) |pt| {
                        try self.output.print(self.allocator, "        {s} {s};\n", .{ try self.mapTypeToC(pt), rv.name });
                    } else {
                        try self.output.print(self.allocator, "        int {s}; /* unit variant */\n", .{rv.name});
                    }
                }
                try self.output.print(self.allocator, "    }} data;\n", .{});
                try self.output.print(self.allocator, "}} {s};\n", .{t.name});
                try self.output.print(self.allocator, "#define {s}_COUNT {d}\n\n", .{ t.name, t.variants.len });
            },
            .alias => {
                try self.output.print(self.allocator, "typedef void* {s};\n\n", .{t.name});
            },
            .trait => {
                // Phase 2: Emit interface vtable struct
                try self.output.print(self.allocator, "/* Interface: {s} */\n", .{t.name});
                try self.output.print(self.allocator, "typedef struct {{\n", .{});
                for (t.methods, 0..) |method, i| {
                    _ = i;
                    try self.output.print(self.allocator, "    void* (*{s})(void* self", .{method.name});
                    for (method.params) |_| {
                        try self.output.appendSlice(self.allocator, ", void*");
                    }
                    try self.output.appendSlice(self.allocator, ");\n");
                }
                try self.output.print(self.allocator, "}} {s}_VTable;\n\n", .{t.name});
                try self.output.print(self.allocator, "typedef struct {{\n", .{});
                try self.output.print(self.allocator, "    void* self;\n", .{});
                try self.output.print(self.allocator, "    const {s}_VTable* vtable;\n", .{t.name});
                try self.output.print(self.allocator, "}} {s};\n\n", .{t.name});
            },
        }
    }

    fn generateModel(self: *CBackend, model: IRModel) !void {
        try self.output.print(self.allocator, "typedef struct {s} {{\n", .{model.name});
        for (model.fields.items) |field| {
            const c_type = self.mapFieldTypeToC(field.type_name);
            try self.output.print(self.allocator, "    {s} {s};\n", .{ c_type, field.name });
        }
        try self.output.print(self.allocator, "}} {s};\n", .{model.name});
        try self.output.print(self.allocator, "#define {s}(...) ({s}*)orbit_model_{s}_create(arena, __VA_ARGS__)\n" ++
            "static inline {s}* orbit_model_{s}_create(OrbitArena* a, ", .{ model.name, model.name, model.name, model.name, model.name });

        for (model.fields.items, 0..) |field, i| {
            const c_type = self.mapFieldTypeToC(field.type_name);
            try self.output.print(self.allocator, "{s} {s}", .{ c_type, field.name });
            if (i < model.fields.items.len - 1) try self.output.appendSlice(self.allocator, ", ");
        }

        try self.output.print(self.allocator, ") {{\n    {s}* m = ({s}*)orbit_alloc(a, sizeof({s}));\n", .{ model.name, model.name, model.name });
        for (model.fields.items) |field| {
            try self.output.print(self.allocator, "    m->{s} = {s};\n", .{ field.name, field.name });
        }
        try self.output.appendSlice(self.allocator, "    return m;\n}\n\n");
    }
};
