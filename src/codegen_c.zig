const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const AtlasConfig = @import("atlas.zig").AtlasConfig;

const RuntimeLoader = @import("codegen/runtime_loader.zig");
const ExpressionGenerator = @import("codegen/expression_gen.zig").ExpressionGenerator;
const StatementGenerator = @import("codegen/statement_gen.zig").StatementGenerator;
const RouteGenerator = @import("codegen/route_gen.zig").RouteGenerator;
const ModelGenerator = @import("codegen/model_gen.zig").ModelGenerator;

pub const CodegenC = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    output: std.ArrayListUnmanaged(u8),
    node_types: *std.AutoHashMapUnmanaged(*Node, []const u8),
    generated_types: std.StringHashMapUnmanaged(bool),
    has_server_init: bool,
    no_kynx: bool,
    config: AtlasConfig,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, node_types: *std.AutoHashMapUnmanaged(*Node, []const u8), no_kynx: bool, config: AtlasConfig) CodegenC {
        return .{
            .allocator = allocator,
            .source = source,
            .output = .empty,
            .node_types = node_types,
            .generated_types = .empty,
            .has_server_init = false,
            .no_kynx = no_kynx,
            .config = config,
        };
    }

    pub fn deinit(self: *CodegenC) void {
        self.output.deinit(self.allocator);
        self.generated_types.deinit(self.allocator);
    }

    pub fn generate(self: *CodegenC, root: *Node) anyerror![]const u8 {
        const headers = try RuntimeLoader.generateHeaders(self.allocator);
        try self.output.appendSlice(self.allocator, headers);

        try self.generateDeclarations(root);

        const main_func = try RuntimeLoader.generateMainFunction(self.allocator, self.has_server_init, false, self.config);
        try self.output.appendSlice(self.allocator, main_func);

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn generateDeclarations(self: *CodegenC, root: *Node) !void {
        if (root.tag != .root) return error.NotARootNode;

        var route_gen = RouteGenerator.init(self.allocator, &self.output, self.source);
        var model_gen = ModelGenerator.init(self.allocator, &self.output, self.source);

        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .model_decl => try model_gen.generate(decl),
                .route_decl => {
                    self.has_server_init = true;
                    try route_gen.generate(decl);
                },
                .fn_decl => try self.generateFunction(decl),
                .const_decl => try self.generateConst(decl),
                .val_decl => try self.generateGlobalVal(decl),
                else => {},
            }
        }

        if (self.has_server_init) {
            try route_gen.generateRouteDispatcher();
        }

        var has_user_main = false;
        for (root.data.root.decls) |decl| {
            if (decl.tag == .fn_decl) {
                const fn_data = decl.data.fn_decl;
                const fn_name = fn_data.name.getText(self.source);
                if (std.mem.eql(u8, fn_name, "main")) {
                    has_user_main = true;
                }
            }
        }

        if (!has_user_main) {
            try self.generateStandaloneMain(root);
        }
    }

    fn generateFunction(self: *CodegenC, node: *Node) !void {
        const fn_data = node.data.fn_decl;
        const fn_name = fn_data.name.getText(self.source);

        if (fn_data.return_type) |ret_type| {
            const ret_type_text = ret_type.getText(self.source);
            try self.output.appendSlice(self.allocator, self.mapOrbitTypeToC(ret_type_text));
        } else {
            try self.output.appendSlice(self.allocator, "void");
        }

        try self.output.append(self.allocator, ' ');
        try self.output.appendSlice(self.allocator, fn_name);
        try self.output.append(self.allocator, '(');

        for (fn_data.params, 0..) |param, i| {
            if (i > 0) try self.output.appendSlice(self.allocator, ", ");

            const param_data = param.data.param;
            if (param_data.type_name) |type_name| {
                const type_text = type_name.getText(self.source);
                try self.output.appendSlice(self.allocator, self.mapOrbitTypeToC(type_text));
            } else {
                try self.output.appendSlice(self.allocator, "orbit_string");
            }

            try self.output.append(self.allocator, ' ');
            try self.output.appendSlice(self.allocator, param_data.name.getText(self.source));
        }

        try self.output.appendSlice(self.allocator, ") {\n");

        var stmt_gen = StatementGenerator.init(self.allocator, &self.output, self.source);
        stmt_gen.indent_level = 1;

        if (fn_data.body.tag == .block) {
            for (fn_data.body.data.block.stmts) |stmt| {
                try stmt_gen.generate(stmt);
            }
        } else {
            try stmt_gen.generate(fn_data.body);
        }

        try self.output.appendSlice(self.allocator, "}\n\n");
    }

    fn generateConst(self: *CodegenC, node: *Node) !void {
        const const_data = node.data.const_decl;

        try self.output.appendSlice(self.allocator, "const orbit_string ");
        try self.output.appendSlice(self.allocator, const_data.name.getText(self.source));
        try self.output.appendSlice(self.allocator, " = ");

        var expr_gen = ExpressionGenerator.init(self.allocator, &self.output, self.source);
        try expr_gen.generate(const_data.value);

        try self.output.appendSlice(self.allocator, ";\n");
    }

    fn generateGlobalVal(self: *CodegenC, node: *Node) !void {
        const val_data = node.data.val_decl;

        if (val_data.type_annotation) |type_ann| {
            const type_text = type_ann.data.type_annotation.base.getText(self.source);
            try self.output.appendSlice(self.allocator, self.mapOrbitTypeToC(type_text));
        } else {
            try self.output.appendSlice(self.allocator, "orbit_string");
        }

        try self.output.append(self.allocator, ' ');
        try self.output.appendSlice(self.allocator, val_data.name.getText(self.source));

        if (val_data.value) |value| {
            try self.output.appendSlice(self.allocator, " = ");
            var expr_gen = ExpressionGenerator.init(self.allocator, &self.output, self.source);
            try expr_gen.generate(value);
        }

        try self.output.appendSlice(self.allocator, ";\n");
    }

    fn generateStandaloneMain(self: *CodegenC, root: *Node) !void {
        try self.output.appendSlice(self.allocator, "int orbit_main(OrbitArena* arena) {\n");

        var stmt_gen = StatementGenerator.init(self.allocator, &self.output, self.source);
        stmt_gen.indent_level = 1;

        for (root.data.root.decls) |decl| {
            if (decl.tag == .expression_stmt) {
                try stmt_gen.generate(decl);
            }
        }

        try self.output.appendSlice(self.allocator, "    return 0;\n}\n\n");
    }

    fn mapOrbitTypeToC(self: *CodegenC, orbit_type: []const u8) []const u8 {
        _ = self;
        if (std.mem.eql(u8, orbit_type, "int")) return "orbit_int";
        if (std.mem.eql(u8, orbit_type, "float")) return "orbit_float";
        if (std.mem.eql(u8, orbit_type, "string")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "bool")) return "orbit_bool";
        if (std.mem.eql(u8, orbit_type, "void")) return "void";
        return "orbit_string";
    }
};
