const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const ir_mod = @import("ir.zig");
const IRModule = ir_mod.IRModule;
const IRFunction = ir_mod.IRFunction;
const IRInstruction = ir_mod.IRInstruction;
const IROpcode = ir_mod.IROpcode;
const IRValue = ir_mod.IRValue;
const IRModel = ir_mod.IRModel;
const IRType = ir_mod.IRType;
const IRTypeDecl = ir_mod.IRTypeDecl;
const IRVariant = ir_mod.IRVariant;

pub const IRBuilder = struct {
    allocator: std.mem.Allocator,
    module: IRModule,
    current_function: ?*IRFunction,
    label_counter: u32,
    source: []const u8,
    main_function: IRFunction,
    node_types: *std.AutoHashMapUnmanaged(*Node, []const u8),
    model_registry: ?*const @import("../sema/model_registry.zig").ModelRegistry,
    variable_types: std.StringHashMap(IRType),
    loop_stack: std.ArrayListUnmanaged(LoopContext),

    const LoopContext = struct {
        start_label: u32,
        end_label: u32,
    };
    
    pub fn init(allocator: std.mem.Allocator, source: []const u8, node_types: *std.AutoHashMapUnmanaged(*Node, []const u8), model_registry: ?*const @import("../sema/model_registry.zig").ModelRegistry) IRBuilder {
        return .{
            .allocator = allocator,
            .module = IRModule.init(allocator),
            .current_function = null,
            .label_counter = 0,
            .source = source,
            .main_function = IRFunction.init(allocator, "orbit_main"),
            .node_types = node_types,
            .model_registry = model_registry,
            .variable_types = std.StringHashMap(IRType).init(allocator),
            .loop_stack = .{},
        };
    }
    
    pub fn deinit(self: *IRBuilder) void {
        self.module.deinit();
        self.loop_stack.deinit(self.allocator);
    }
    
    fn getNodeType(self: *IRBuilder, node: *Node) IRType {
        if (self.node_types.get(node)) |type_name| {
            std.debug.print("getNodeType: node tag {s} has type '{s}'\n", .{@tagName(node.tag), type_name});
            for (self.module.types.items) |t| {
                if (std.mem.eql(u8, t.name, type_name)) {
                    if (t.kind == .enumeration) return .{ .enumeration = type_name };
                    if (t.kind == .union_type) return .{ .tagged_union = type_name };
                }
            }

            const t = IRType.fromString(type_name);
            if (t != .unknown) return t;
        } else {
            std.debug.print("getNodeType: node tag {s} NOT found in node_types\n", .{@tagName(node.tag)});
        }
        
        // Fallback for identifier types if we can find them in the variable table
        if (node.tag == .identifier) {
            const name = node.data.identifier.getText(self.source);
            if (self.variable_types.get(name)) |t| return t;
            
            // Check in module types
            for (self.module.types.items) |t| {
                if (std.mem.eql(u8, t.name, name)) {
                    if (t.kind == .enumeration) return .{ .enumeration = name };
                    if (t.kind == .union_type) return .{ .tagged_union = name };
                }
            }

            // Check if it's a known model name (Type name)
            if (name.len > 0 and std.ascii.isUpper(name[0])) return .{ .model = name };
            if (self.model_registry) |reg| {
                if (reg.hasModel(name)) return .{ .model = name };
            }
        }
        
        if (node.tag == .call) {
            const call = node.data.call;
            if (call.func.tag == .member_access) {
                const ma = call.func.data.member_access;
                const obj_name = if (ma.object.tag == .identifier) ma.object.data.identifier.getText(self.source) else "";
                const member_name = ma.member.getText(self.source);
                if (std.mem.eql(u8, obj_name, "file") and std.mem.eql(u8, member_name, "read")) return .{ .result = null };
                
                const obj_type = self.getNodeType(ma.object);
                if (obj_type == .string) {
                    if (std.mem.eql(u8, member_name, "at")) return .int;
                    if (std.mem.eql(u8, member_name, "slice")) return .string;
                }
                
                // Static call: Status.Error(...)
                if (obj_name.len > 0 and std.ascii.isUpper(obj_name[0])) {
                    for (self.module.types.items) |t| {
                        if (std.mem.eql(u8, t.name, obj_name)) {
                            if (t.kind == .union_type) return .{ .tagged_union = obj_name };
                        }
                    }
                }
            } else {
                const name = call.func.data.identifier.getText(self.source);
                for (self.module.functions.items) |f| {
                    if (std.mem.eql(u8, f.name, name)) return f.return_type;
                }
            }
        }

        if (node.tag == .member_access) {
            const ma = node.data.member_access;
            const obj_name = if (ma.object.tag == .identifier) ma.object.data.identifier.getText(self.source) else "";
            if (obj_name.len > 0 and std.ascii.isUpper(obj_name[0])) {
                 for (self.module.types.items) |t| {
                    if (std.mem.eql(u8, t.name, obj_name)) {
                        if (t.kind == .enumeration) return .{ .enumeration = obj_name };
                        if (t.kind == .union_type) return .{ .tagged_union = obj_name };
                    }
                }
            }

            const obj_type = self.getNodeType(ma.object);
            switch (obj_type) {
                .model => |m_name| {
                    if (self.model_registry) |reg| {
                        if (reg.getField(m_name, ma.member.getText(self.source))) |field| {
                            return IRType.fromString(field.type_name);
                        }
                    }
                },
                else => {},
            }
        }

        return .unknown;
    }
    
    fn resolveType(self: *IRBuilder, type_name: []const u8) IRType {
        for (self.module.types.items) |t| {
            if (std.mem.eql(u8, t.name, type_name)) {
                if (t.kind == .enumeration) return .{ .enumeration = type_name };
                if (t.kind == .union_type) return .{ .tagged_union = type_name };
            }
        }
        return IRType.fromString(type_name);
    }
    
    pub fn build(self: *IRBuilder, root: *Node) !IRModule {
        if (root.tag != .root) return error.NotARootNode;
        
        // Pass 1: Register all types (Enums, Unions, Models, Type aliases)
        // This ensures types are known before they are used in function signatures or bodies.
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .enum_decl => try self.buildEnumDecl(decl),
                .union_decl => try self.buildUnionDecl(decl),
                .model_decl => try self.buildModel(decl),
                .type_decl => try self.buildTypeDecl(decl),
                else => {},
            }
        }
        std.debug.print("--- REGISTERED TYPES ---\n", .{});
        for (self.module.types.items) |t| {
            std.debug.print("Type: {s}, Kind: {s}\n", .{t.name, @tagName(t.kind)});
        }
        std.debug.print("------------------------\n", .{});

        // Pass 2: Register all function signatures (including routes)
        // This ensures functions are known before they are called.
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .fn_decl => {
                    const fn_data = decl.data.fn_decl;
                    var func = IRFunction.init(self.allocator, fn_data.name.getText(self.source));
                    if (fn_data.return_type) |rt| {
                        func.return_type = self.resolveType(rt.getText(self.source));
                    }
                    
                    // Track param types
                    var param_types = std.ArrayListUnmanaged(IRType){};
                    var param_names = std.ArrayListUnmanaged([]const u8){};
                    for (fn_data.params) |p| {
                       try param_names.append(self.allocator, p.data.param.name.getText(self.source));
                       const pt = if (p.data.param.type_name) |tn| self.resolveType(tn.getText(self.source)) else .int;
                       try param_types.append(self.allocator, pt);
                    }
                    func.params = try param_names.toOwnedSlice(self.allocator);
                    func.param_types = try param_types.toOwnedSlice(self.allocator);

                    try self.module.addFunction(func);
                },
                .route_decl => {
                    const route_data = decl.data.route_decl;
                    const raw_method = route_data.method.getText(self.source);
                    const raw_path = route_data.path.getText(self.source);
                    
                    const method = if (raw_method.len >= 2 and raw_method[0] == '"') raw_method[1..raw_method.len-1] else raw_method;
                    const path = if (raw_path.len >= 2 and raw_path[0] == '"') raw_path[1..raw_path.len-1] else raw_path;

                    const route_name = try std.fmt.allocPrint(self.allocator, "route_{s}_{s}", .{ method, path });
                    var func = IRFunction.init(self.allocator, route_name);
                    func.route_info = .{
                        .method = method,
                        .path = path,
                    };
                    // Routes currently don't have explicit parameters in AST, but might in future.
                    // For now, they implicitly take a context or request object.
                    // We'll leave params empty for now.
                    
                    try self.module.addFunction(func);
                },
                else => {},
            }
        }

        // Pass 3: Build function bodies and other declarations (const, val, expression_stmt)
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .fn_decl => {
                    const fn_data = decl.data.fn_decl;
                    const name = fn_data.name.getText(self.source);
                    // Find the previously registered function
                    for (self.module.functions.items) |*f| {
                        if (std.mem.eql(u8, f.name, name)) {
                            self.current_function = f;
                            // Add parameters to variable_types for scope
                            for (f.params, f.param_types) |p_name, p_type| {
                                try self.variable_types.put(p_name, p_type);
                            }

                            if (fn_data.body.tag == .block) {
                                for (fn_data.body.data.block.stmts) |stmt| {
                                    try self.buildStmt(stmt);
                                }
                            } else {
                                try self.buildStmt(fn_data.body);
                            }
                            // Clear parameters from variable_types
                            for (f.params) |p_name| {
                                _ = self.variable_types.remove(p_name);
                            }
                            break;
                        }
                    }
                    self.current_function = null;
                },
                .route_decl => {
                    const route_data = decl.data.route_decl;
                    const raw_method = route_data.method.getText(self.source);
                    const raw_path = route_data.path.getText(self.source);
                    
                    const method = if (raw_method.len >= 2 and raw_method[0] == '"') raw_method[1..raw_method.len-1] else raw_method;
                    const path = if (raw_path.len >= 2 and raw_path[0] == '"') raw_path[1..raw_path.len-1] else raw_path;

                    const route_name = try std.fmt.allocPrint(self.allocator, "route_{s}_{s}", .{ method, path });
                    
                    for (self.module.functions.items) |*f| {
                        if (std.mem.eql(u8, f.name, route_name)) {
                            self.current_function = f;
                            if (route_data.body.tag == .block) {
                                for (route_data.body.data.block.stmts) |stmt| {
                                    try self.buildStmt(stmt);
                                }
                            } else {
                                try self.buildStmt(route_data.body);
                            }
                            break;
                        }
                    }
                    self.current_function = null;
                },
                .const_decl => try self.buildConst(decl),
                .val_decl => try self.buildVal(decl),
                .expression_stmt => {
                    self.current_function = &self.main_function;
                    try self.buildStmt(decl);
                    self.current_function = null;
                },
                else => {}, // Types already built in Pass 1
            }
        }
        
        if (self.main_function.instructions.items.len > 0) {
            try self.module.addFunction(self.main_function);
        } else if (self.module.functions.items.len == 0) {
            // Ensure at least one function exists if the module is empty
            try self.module.addFunction(self.main_function);
        }
        
        return self.module;
    }
    
    fn buildDecl(self: *IRBuilder, node: *Node) !void {
        switch (node.tag) {
            .fn_decl => try self.buildFunction(node),
            .route_decl => try self.buildRoute(node),
            .const_decl => try self.buildConst(node),
            .val_decl => try self.buildVal(node),
            .model_decl => try self.buildModel(node),
            .type_decl => try self.buildTypeDecl(node),
            .enum_decl => try self.buildEnumDecl(node),
            .union_decl => try self.buildUnionDecl(node),
            .expression_stmt => {
                self.current_function = &self.main_function;
                try self.buildStmt(node);
                self.current_function = null;
            },
            else => {},
        }
    }
    
    fn buildModel(self: *IRBuilder, node: *Node) !void {
        const model_data = node.data.model_decl;
        var model = IRModel.init(self.allocator, model_data.name.getText(self.source));
        
        for (model_data.fields) |field| {
            const field_data = field.data.field_decl;
            try model.fields.append(self.allocator, .{
                .name = field_data.name.getText(self.source),
                .type_name = field_data.type_name.getText(self.source),
            });
        }
        
        try self.module.models.append(self.allocator, model);
    }

    fn buildTypeDecl(self: *IRBuilder, node: *Node) !void {
        const type_data = node.data.type_decl;
        const ir_type = IRTypeDecl{
            .name = try self.allocator.dupe(u8, type_data.name.getText(self.source)),
            .kind = .alias,
            .variants = &.{},
            .rich_variants = &.{},
            .methods = &.{},
        };
        try self.module.types.append(self.allocator, ir_type);
    }

    fn buildEnumDecl(self: *IRBuilder, node: *Node) !void {
        const enum_data = node.data.enum_decl;
        var variants = std.ArrayListUnmanaged([]const u8){};
        var rich = std.ArrayListUnmanaged(IRVariant){};
        for (enum_data.variants) |v| {
            const vname = try self.allocator.dupe(u8, v.getText(self.source));
            try variants.append(self.allocator, vname);
            try rich.append(self.allocator, IRVariant{
                .name = vname,
                .payload_type = null,
                .fields = &.{},
            });
        }
        const ir_type = IRTypeDecl{
            .name = try self.allocator.dupe(u8, enum_data.name.getText(self.source)),
            .kind = .enumeration,
            .variants = try variants.toOwnedSlice(self.allocator),
            .rich_variants = try rich.toOwnedSlice(self.allocator),
            .methods = &.{},
        };
        try self.module.types.append(self.allocator, ir_type);
    }

    fn buildUnionDecl(self: *IRBuilder, node: *Node) !void {
        const union_data = node.data.union_decl;
        var variants = std.ArrayListUnmanaged([]const u8){};
        var rich = std.ArrayListUnmanaged(IRVariant){};
        for (union_data.variants) |v| {
            var vname: []const u8 = undefined;
            var payload_type: ?IRType = null;
            
            if (v.tag == .union_variant) {
                const uv = v.data.union_variant;
                vname = try self.allocator.dupe(u8, uv.name.getText(self.source));
                if (uv.payload) |p| {
                    payload_type = IRType.fromString(p.data.identifier.getText(self.source));
                }
            } else {
                vname = try self.allocator.dupe(u8, v.data.identifier.getText(self.source));
            }
            
            try variants.append(self.allocator, vname);
            try rich.append(self.allocator, IRVariant{
                .name = vname,
                .payload_type = payload_type,
                .fields = &.{},
            });
        }
        const ir_type = IRTypeDecl{
            .name = try self.allocator.dupe(u8, union_data.name.getText(self.source)),
            .kind = .union_type,
            .variants = try variants.toOwnedSlice(self.allocator),
            .rich_variants = try rich.toOwnedSlice(self.allocator),
            .methods = &.{},
        };
        try self.module.types.append(self.allocator, ir_type);
    }
    
    fn buildFunction(self: *IRBuilder, node: *Node) !void {
        const fn_data = node.data.fn_decl;
        const fn_name = fn_data.name.getText(self.source);
        std.debug.print("Builder buildFunction: {s}\n", .{fn_name});
        var func = IRFunction.init(self.allocator, fn_name);
        
        // Phase 2: Set return type from annotation
        if (fn_data.return_type) |rt| {
            func.return_type = IRType.fromString(rt.getText(self.source));
        }
        
        self.current_function = &func;
        
        if (fn_data.body.tag == .block) {
            for (fn_data.body.data.block.stmts) |stmt| {
                try self.buildStmt(stmt);
            }
        } else {
            try self.buildStmt(fn_data.body);
        }
        
        try self.module.addFunction(func);
        self.current_function = null;
    }
    
    fn buildRoute(self: *IRBuilder, node: *Node) !void {
        const route_data = node.data.route_decl;
        const raw_method = route_data.method.getText(self.source);
        const raw_path = route_data.path.getText(self.source);
        
        const method = if (raw_method.len >= 2 and raw_method[0] == '"') raw_method[1..raw_method.len-1] else raw_method;
        const path = if (raw_path.len >= 2 and raw_path[0] == '"') raw_path[1..raw_path.len-1] else raw_path;

        const route_name = try std.fmt.allocPrint(self.allocator, "route_{s}_{s}", .{ method, path });
        var func = IRFunction.init(self.allocator, route_name);
        func.route_info = .{
            .method = method,
            .path = path,
        };
        self.current_function = &func;
        
        if (route_data.body.tag == .block) {
            for (route_data.body.data.block.stmts) |stmt| {
                try self.buildStmt(stmt);
            }
        } else {
            try self.buildStmt(route_data.body);
        }
        
        try self.module.addFunction(func);
        self.current_function = null;
    }
    
    fn buildConst(self: *IRBuilder, node: *Node) !void {
        const const_data = node.data.const_decl;
        const value = try self.buildExpr(const_data.value);
        try self.module.addGlobal(const_data.name.getText(self.source), value);
    }
    
    fn buildVal(self: *IRBuilder, node: *Node) !void {
        const val_data = node.data.val_decl;
        const name = val_data.name.getText(self.source);
        if (val_data.value) |value_node| {
            const value = try self.buildExpr(value_node);
            
            // Track variable type for later access
            const var_type: IRType = switch (value) {
                .register => |r| if (self.current_function) |f| f.register_types.items[r] else .unknown,
                .int => .int,
                .float => .float,
                .string => .string,
                .bool => .bool,
                else => .unknown,
            };
            try self.variable_types.put(name, var_type);

            var instr = IRInstruction.init(.decl_var);
            instr.operand1 = IRValue{ .string = name };
            instr.operand2 = value;
            try self.current_function.?.emit(self.allocator, instr);
        }
    }
    
    fn buildStmt(self: *IRBuilder, node: *Node) anyerror!void {
        switch (node.tag) {
            .expression_stmt => {
                _ = try self.buildExpr(node.data.expression_stmt.expr);
            },
            .return_stmt => {
                const value = node.data.return_stmt.expr;
                const result = if (value) |v| try self.buildExpr(v) else IRValue.none;
                var instr = IRInstruction.init(.ret);
                instr.operand1 = result;
                try self.current_function.?.emit(self.allocator, instr);
            },
            .return_ok => {
                const expr_val = try self.buildExpr(node.data.return_ok.expr);
                const status_code = if (node.data.return_ok.status) |s|
                    std.fmt.parseInt(i32, s.getText(self.source), 10) catch 200
                else
                    200;
                
                var instr = IRInstruction.init(.call);
                instr.operand1 = IRValue{ .string = "orbit_response_json" };
                
                // Allocate a register for the result of the call
                const dest_reg = try self.current_function.?.allocRegister(self.allocator, .response);
                instr.dest = dest_reg;
                
                var arg1 = IRInstruction.init(.arg);
                arg1.operand1 = IRValue{ .int = @intCast(status_code) };
                
                var arg2 = IRInstruction.init(.arg);
                arg2.operand1 = expr_val;
                
                try self.current_function.?.emit(self.allocator, arg1);
                try self.current_function.?.emit(self.allocator, arg2);
                try self.current_function.?.emit(self.allocator, instr);
                
                var ret_instr = IRInstruction.init(.ret);
                ret_instr.operand1 = IRValue{ .register = dest_reg };
                try self.current_function.?.emit(self.allocator, ret_instr);
            },
            .err_stmt => {
                const expr_val = try self.buildExpr(node.data.err_stmt.message);
                const status_code = std.fmt.parseInt(i32, node.data.err_stmt.code.getText(self.source), 10) catch 500;
                
                var instr = IRInstruction.init(.call);
                instr.operand1 = IRValue{ .string = "orbit_response_error" };

                const dest_reg = try self.current_function.?.allocRegister(self.allocator, .response);
                instr.dest = dest_reg;
                
                var arg1 = IRInstruction.init(.arg);
                arg1.operand1 = IRValue{ .int = @intCast(status_code) };
                
                var arg2 = IRInstruction.init(.arg);
                arg2.operand1 = expr_val;
                
                try self.current_function.?.emit(self.allocator, arg1);
                try self.current_function.?.emit(self.allocator, arg2);
                try self.current_function.?.emit(self.allocator, instr);

                var ret_instr = IRInstruction.init(.ret);
                ret_instr.operand1 = IRValue{ .register = dest_reg };
                try self.current_function.?.emit(self.allocator, ret_instr);
            },
            .val_decl => try self.buildVal(node),
            .if_stmt => try self.buildIf(node),
            .while_stmt => try self.buildWhile(node),
            .block => {
                for (node.data.block.stmts) |stmt| {
                    try self.buildStmt(stmt);
                }
            },
            .match_stmt => try self.buildMatch(node),
            .assignment => _ = try self.buildAssignment(node),
            .break_stmt => {
                if (self.loop_stack.items.len > 0) {
                    const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                    var jump = IRInstruction.init(.jump);
                    jump.operand1 = IRValue{ .label = ctx.end_label };
                    try self.current_function.?.emit(self.allocator, jump);
                }
            },
            .continue_stmt => {
                if (self.loop_stack.items.len > 0) {
                    const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                    var jump = IRInstruction.init(.jump);
                    jump.operand1 = IRValue{ .label = ctx.start_label };
                    try self.current_function.?.emit(self.allocator, jump);
                }
            },
            else => {},
        }
    }
    
    fn buildExpr(self: *IRBuilder, node: *Node) anyerror!IRValue {
        return switch (node.tag) {
            .assignment => try self.buildAssignment(node),
            .integer_literal => IRValue{ .int = std.fmt.parseInt(i64, node.data.integer_literal.getText(self.source), 10) catch 0 },
            .float_literal => IRValue{ .float = std.fmt.parseFloat(f64, node.data.float_literal.getText(self.source)) catch 0.0 },
            .string_literal => blk: {
                const full = node.data.string_literal.getText(self.source);
                if (full.len >= 2) {
                    break :blk IRValue{ .string = full[1 .. full.len - 1] };
                }
                break :blk IRValue{ .string = full };
            },
            .boolean_literal => IRValue{ .bool = std.mem.eql(u8, node.data.boolean_literal.getText(self.source), "true") },
            .identifier => blk: {
                const type_val = self.getNodeType(node);
                const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
                var instr = IRInstruction.init(.load_var);
                instr.dest = reg;
                instr.operand1 = IRValue{ .string = node.data.identifier.getText(self.source) };
                try self.current_function.?.emit(self.allocator, instr);
                break :blk IRValue{ .register = reg };
            },
            .binary_op => try self.buildBinaryOp(node),
            .call => try self.buildCall(node),
            .field_init => try self.buildExpr(node.data.field_init.value),
            .member_access => try self.buildMemberAccess(node),
            .array_literal => blk: {
                const arr = node.data.array_literal;
                const reg = try self.current_function.?.allocRegister(self.allocator, .{ .list = null });
                
                var create = IRInstruction.init(.list_create);
                create.dest = reg;
                
                // Heuristic for element size
                var elem_size: i64 = 8; // Default to pointer size
                if (arr.elements.len > 0) {
                    if (arr.elements[0].tag == .integer_literal) {
                        elem_size = 4; // orbit_int
                    }
                }
                
                create.operand1 = IRValue{ .int = elem_size };
                create.operand2 = IRValue{ .int = @intCast(arr.elements.len) };
                try self.current_function.?.emit(self.allocator, create);
                
                for (arr.elements) |elem| {
                    const val = try self.buildExpr(elem);
                    var push = IRInstruction.init(.list_push);
                    push.operand1 = IRValue{ .register = reg };
                    push.operand2 = val;
                    const void_reg = try self.current_function.?.allocRegister(self.allocator, .void);
                    push.dest = void_reg;
                    try self.current_function.?.emit(self.allocator, push);
                }
                break :blk IRValue{ .register = reg };
            },
            .object_literal => blk: {
                const obj = node.data.object_literal;
                const reg = try self.current_function.?.allocRegister(self.allocator, .{ .map = null });
                
                var create = IRInstruction.init(.map_create);
                create.dest = reg;
                
                // Heuristic for value size
                var val_size: i64 = 8;
                if (obj.fields.len > 0) {
                    const fi = obj.fields[0].data.field_init;
                    if (fi.value.tag == .integer_literal) {
                        val_size = 4;
                    }
                }
                
                create.operand1 = IRValue{ .int = val_size };
                try self.current_function.?.emit(self.allocator, create);
                
                for (obj.fields) |field| {
                    const fi = field.data.field_init;
                    const key_token = fi.name;
                    var key_str = key_token.getText(self.source);
                    if (key_token.tag == .StringLiteral) {
                        if (key_str.len >= 2) key_str = key_str[1..key_str.len-1];
                    }
                    
                    const val = try self.buildExpr(fi.value);
                    
                    var map_set = IRInstruction.init(.map_set);
                    map_set.operand1 = IRValue{ .register = reg };
                    map_set.operand2 = IRValue{ .string = key_str };
                    map_set.operand3 = val;
                    // dest is unused/void
                    const void_reg = try self.current_function.?.allocRegister(self.allocator, .void);
                    map_set.dest = void_reg;
                    try self.current_function.?.emit(self.allocator, map_set);
                }
                break :blk IRValue{ .register = reg };
            },
            .rescue_expr => blk: {
                const r = node.data.rescue_expr;
                const expr_val = try self.buildExpr(r.expr);
                
                const is_ok_reg = try self.current_function.?.allocRegister(self.allocator, .bool);
                var chk = IRInstruction.init(.result_is_ok);
                chk.operand1 = expr_val;
                chk.dest = is_ok_reg;
                try self.current_function.?.emit(self.allocator, chk);
                
                const err_label = self.allocLabel();
                const end_label = self.allocLabel();
                
                var br = IRInstruction.init(.jump_if_false);
                br.operand1 = IRValue{ .register = is_ok_reg };
                br.operand2 = IRValue{ .label = err_label };
                try self.current_function.?.emit(self.allocator, br);
                
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.begin_block));
                const unwrap_reg = try self.current_function.?.allocRegister(self.allocator, self.getNodeType(node));
                var unwrap = IRInstruction.init(.result_unwrap);
                unwrap.operand1 = expr_val;
                unwrap.dest = unwrap_reg;
                try self.current_function.?.emit(self.allocator, unwrap);
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.end_block));
                
                var jmp_end = IRInstruction.init(.jump);
                jmp_end.operand1 = IRValue{ .label = end_label };
                try self.current_function.?.emit(self.allocator, jmp_end);
                
                var lbl_err = IRInstruction.init(.label);
                lbl_err.operand1 = IRValue{ .label = err_label };
                try self.current_function.?.emit(self.allocator, lbl_err);
                
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.begin_block));
                if (r.message.tag == .err_stmt or r.message.tag == .err_shortcut) {
                    try self.buildStmt(r.message);
                } else {
                    const fallback_val = try self.buildExpr(r.message);
                    var copy_instr = IRInstruction.init(.copy);
                    copy_instr.operand1 = fallback_val;
                    copy_instr.dest = unwrap_reg;
                    try self.current_function.?.emit(self.allocator, copy_instr);
                }
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.end_block));
                
                var lbl_end = IRInstruction.init(.label);
                lbl_end.operand1 = IRValue{ .label = end_label };
                try self.current_function.?.emit(self.allocator, lbl_end);
                
                break :blk IRValue{ .register = unwrap_reg };
            },
            .unary_op => try self.buildUnaryOp(node),
            else => IRValue.none,
         };
     }
     
     fn buildUnaryOp(self: *IRBuilder, node: *Node) !IRValue {
         const u = node.data.unary_op;
         const operand = try self.buildExpr(u.operand);
         
         if (u.op.tag == .Minus) {
             if (operand == .int) {
                 return IRValue{ .int = -operand.int };
             }
             if (operand == .float) {
                 return IRValue{ .float = -operand.float };
             }
             
             const type_val = self.getNodeType(node);
             const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
             var instr = IRInstruction.init(.neg);
             instr.dest = reg;
             instr.operand1 = operand;
             try self.current_function.?.emit(self.allocator, instr);
             return IRValue{ .register = reg };
         }
         
         if (u.op.tag == .Bang) {
             const type_val = self.getNodeType(node);
             const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
             var instr = IRInstruction.init(.not_op);
             instr.dest = reg;
             instr.operand1 = operand;
             try self.current_function.?.emit(self.allocator, instr);
             return IRValue{ .register = reg };
         }
         
         return operand;
     }

    fn buildMemberAccess(self: *IRBuilder, node: *Node) !IRValue {
        const ma = node.data.member_access;
        const member_name = ma.member.getText(self.source);
        
        // Check if object is identifier (could be Type or Enum)
        if (ma.object.tag == .identifier) {
            const obj_name = ma.object.data.identifier.getText(self.source);
            // Check if first char is UpperCase -> Enum/Type constant
            if (std.ascii.isUpper(obj_name[0])) {
                  var is_union = false;
                  for (self.module.types.items) |t| {
                      if (std.mem.eql(u8, t.name, obj_name)) {
                          if (t.kind == .union_type) is_union = true;
                      }
                  }
                  std.debug.print("buildMemberAccess: obj_name={s}, member_name={s}, is_union={}\n", .{obj_name, member_name, is_union});

                  const full_name = try std.fmt.allocPrint(self.allocator, "{s}_TAG_{s}", .{obj_name, member_name});
                  
                  if (is_union) {
                      const union_reg = try self.current_function.?.allocRegister(self.allocator, .{ .tagged_union = obj_name });
                      var instr = IRInstruction.init(.union_create);
                      instr.dest = union_reg;
                      instr.operand1 = IRValue{ .string = full_name };
                      instr.operand2 = IRValue{ .int = 0 };
                      try self.current_function.?.emit(self.allocator, instr);
                      return IRValue{ .register = union_reg };
                  } else {
                      const type_val = self.getNodeType(node);
                      const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
                      var instr = IRInstruction.init(.load_var);
                      instr.dest = reg;
                      instr.operand1 = IRValue{ .string = full_name };
                      try self.current_function.?.emit(self.allocator, instr);
                      return IRValue{ .register = reg };
                  }
            }
        }
        
        const obj_type = self.getNodeType(ma.object);
        if (obj_type == .string and std.mem.eql(u8, member_name, "length")) {
             const obj_val = try self.buildExpr(ma.object);
             var arg_instr = IRInstruction.init(.arg);
             arg_instr.operand1 = obj_val;
             try self.current_function.?.emit(self.allocator, arg_instr);
             
             const reg = try self.current_function.?.allocRegister(self.allocator, .int);
             var call_instr = IRInstruction.init(.call);
             call_instr.dest = reg;
             call_instr.operand1 = IRValue{ .string = "strlen" };
             try self.current_function.?.emit(self.allocator, call_instr);
             return IRValue{ .register = reg };
        }
        
        // Object access
        const obj_val = try self.buildExpr(ma.object);
        const type_val = self.getNodeType(node);
        const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
        var instr = IRInstruction.init(.load_field);
        instr.dest = reg;
        instr.operand1 = obj_val;
        instr.operand2 = IRValue{ .string = member_name };
        try self.current_function.?.emit(self.allocator, instr);
        return IRValue{ .register = reg };
    }
    
    fn buildBinaryOp(self: *IRBuilder, node: *Node) !IRValue {
        const bin_data = node.data.binary_op;
        const lhs = try self.buildExpr(bin_data.lhs);
        const rhs = try self.buildExpr(bin_data.rhs);
        
        const opcode: IROpcode = switch (bin_data.op.tag) {
            .Plus => .add,
            .Minus => .sub,
            .Asterisk => .mul,
            .Slash => .div,
            .DoubleEqual => .eq,
            .NotEqual => .ne,
            .Less => .lt,
            .LessEqual => .le,
            .Greater => .gt,
            .GreaterEqual => .ge,
            .DoubleAmpersand => .and_op,
            .DoublePipe => .or_op,
            else => .nop,
        };
        
        const type_val = self.getNodeType(node);
        const reg = try self.current_function.?.allocRegister(self.allocator, type_val);
        var instr = IRInstruction.init(opcode);
        instr.dest = reg;
        instr.operand1 = lhs;
        instr.operand2 = rhs;
        try self.current_function.?.emit(self.allocator, instr);
        
        return IRValue{ .register = reg };
    }
    
    fn buildCall(self: *IRBuilder, node: *Node) !IRValue {
        const type_val = self.getNodeType(node);
        const reg = try self.current_function.?.allocRegister(self.allocator, type_val);

        if (node.data.call.func.tag == .member_access) {
            const ma = node.data.call.func.data.member_access;
            const member_name = ma.member.getText(self.source);
            
            // Intercept collection methods
            if (std.mem.eql(u8, member_name, "push")) {
                 const obj = try self.buildExpr(ma.object);
                 if (node.data.call.args.len == 1) {
                     const val = try self.buildExpr(node.data.call.args[0]);
                     var instr = IRInstruction.init(.list_push);
                     instr.operand1 = obj;
                     instr.operand2 = val;
                     const push_res = try self.current_function.?.allocRegister(self.allocator, .void);
                     instr.dest = push_res; 
                     try self.current_function.?.emit(self.allocator, instr);
                     return IRValue{ .register = push_res };
                 }
            } else if (std.mem.eql(u8, member_name, "at")) {
                 const obj = try self.buildExpr(ma.object);
                 const obj_type = self.getNodeType(ma.object);
                 if (obj_type == .string and node.data.call.args.len == 1) {
                     const idx = try self.buildExpr(node.data.call.args[0]);
                     var arg_instr = IRInstruction.init(.arg);
                     arg_instr.operand1 = obj;
                     try self.current_function.?.emit(self.allocator, arg_instr);
                     
                     var arg2_instr = IRInstruction.init(.arg);
                     arg2_instr.operand1 = idx;
                     try self.current_function.?.emit(self.allocator, arg2_instr);
                     
                     var call_instr = IRInstruction.init(.call);
                     call_instr.dest = reg;
                     call_instr.operand1 = IRValue{ .string = "orbit_string_at" };
                     try self.current_function.?.emit(self.allocator, call_instr);
                     return IRValue{ .register = reg };
                 }
            } else if (std.mem.eql(u8, member_name, "slice")) {
                 const obj = try self.buildExpr(ma.object);
                 const obj_type = self.getNodeType(ma.object);
                 if (obj_type == .string and node.data.call.args.len == 2) {
                     const start_val = try self.buildExpr(node.data.call.args[0]);
                     const end_val = try self.buildExpr(node.data.call.args[1]);
                     
                     var arg_instr = IRInstruction.init(.arg);
                     arg_instr.operand1 = obj;
                     try self.current_function.?.emit(self.allocator, arg_instr);
                     
                     var arg2_instr = IRInstruction.init(.arg);
                     arg2_instr.operand1 = start_val;
                     try self.current_function.?.emit(self.allocator, arg2_instr);
                     
                     var arg3_instr = IRInstruction.init(.arg);
                     arg3_instr.operand1 = end_val;
                     try self.current_function.?.emit(self.allocator, arg3_instr);
                     
                     var call_instr = IRInstruction.init(.call);
                     call_instr.dest = reg;
                     call_instr.operand1 = IRValue{ .string = "orbit_string_slice" };
                     try self.current_function.?.emit(self.allocator, call_instr);
                     return IRValue{ .register = reg };
                 }
            } else if (std.mem.eql(u8, member_name, "get")) {
                 const obj = try self.buildExpr(ma.object);
                 
                 if (node.data.call.args.len == 1) {
                     const key_arg = try self.buildExpr(node.data.call.args[0]);
                     
                     // Heuristic: Int for List, others for Map
                     var use_list = true;
                     if (key_arg == .string) {
                         use_list = false;
                     }
                     
                     var instr = IRInstruction.init(if (use_list) .list_get else .map_get);
                     instr.operand1 = obj;
                     instr.operand2 = key_arg;
                     const get_res = try self.current_function.?.allocRegister(self.allocator, self.getNodeType(node));
                     instr.dest = get_res;
                     try self.current_function.?.emit(self.allocator, instr);
                     return IRValue{ .register = get_res };
                 }
            } else if (std.mem.eql(u8, member_name, "len")) {
                 const obj = try self.buildExpr(ma.object);
                 const obj_type = self.getNodeType(ma.object);
                 
                  if (obj_type == .map) {
                      var arg = IRInstruction.init(.arg);
                      arg.operand1 = obj;
                      try self.current_function.?.emit(self.allocator, arg);
                      const count_res = try self.current_function.?.allocRegister(self.allocator, .int);
                      const call = IRInstruction.call(count_res, "orbit_map_count", &.{});
                      try self.current_function.?.emit(self.allocator, call);
                      return IRValue{ .register = count_res };
                  } else if (obj_type == .string) {
                      var arg = IRInstruction.init(.arg);
                      arg.operand1 = obj;
                      try self.current_function.?.emit(self.allocator, arg);
                      const len_res = try self.current_function.?.allocRegister(self.allocator, .int);
                      const call = IRInstruction.call(len_res, "strlen", &.{});
                      try self.current_function.?.emit(self.allocator, call);
                      return IRValue{ .register = len_res };
                  } else {
                      var instr = IRInstruction.init(.list_len);
                      instr.operand1 = obj;
                      const len_res = try self.current_function.?.allocRegister(self.allocator, .int);
                      instr.dest = len_res;
                      try self.current_function.?.emit(self.allocator, instr);
                      return IRValue{ .register = len_res };
                  }
            }
        }

        if (node.data.call.func.tag == .member_access) {
            const ma = node.data.call.func.data.member_access;
            if (ma.object.tag == .identifier) {
                const obj_name = ma.object.data.identifier.getText(self.source);
                if (obj_name.len > 0 and std.ascii.isUpper(obj_name[0])) {
                    const member_name = ma.member.getText(self.source);
                    const tag_name = try std.fmt.allocPrint(self.allocator, "{s}_TAG_{s}", .{obj_name, member_name});
                    
                    const union_reg = try self.current_function.?.allocRegister(self.allocator, .{ .tagged_union = obj_name });
                    var instr = IRInstruction.init(.union_create);
                    instr.dest = union_reg;
                    instr.operand1 = IRValue{ .string = tag_name }; // Discriminant
                    
                    if (node.data.call.args.len > 0) {
                        instr.operand2 = try self.buildExpr(node.data.call.args[0]);
                    } else {
                        instr.operand2 = IRValue{ .int = 0 }; // Unit variant
                    }
                    
                    try self.current_function.?.emit(self.allocator, instr);
                    return IRValue{ .register = union_reg };
                }
            }
        }

        var param_vals = try self.allocator.alloc(IRValue, node.data.call.args.len);
        defer self.allocator.free(param_vals);
        for (node.data.call.args, 0..) |arg, i| {
            param_vals[i] = try self.buildExpr(arg);
        }
        for (param_vals) |param_val| {
            var arg_instr = IRInstruction.init(.arg);
            arg_instr.operand1 = param_val;
            try self.current_function.?.emit(self.allocator, arg_instr);
        }

        var func_name: []const u8 = "";
        if (node.data.call.func.tag == .member_access) {
            const ma = node.data.call.func.data.member_access;
            const obj_name = if (ma.object.tag == .identifier) ma.object.data.identifier.getText(self.source) else "";
            const member_name = ma.member.getText(self.source);
            
            // Map common module calls to runtime functions
            if (std.mem.eql(u8, obj_name, "file") and std.mem.eql(u8, member_name, "read")) {
                func_name = "orbit_file_read";
                // Add first argument implicitly if needed, but here it expects Arena* which we'll handle in CBackend or by passing current arena
            } else if (std.mem.eql(u8, obj_name, "file") and std.mem.eql(u8, member_name, "write")) {
                func_name = "orbit_file_write";
            } else if (std.mem.eql(u8, obj_name, "file") and std.mem.eql(u8, member_name, "list_dir")) {
                func_name = "orbit_file_list_dir";
            } else if (std.mem.eql(u8, obj_name, "os") and std.mem.eql(u8, member_name, "exec")) {
                func_name = "orbit_os_exec";
            } else if (std.mem.eql(u8, obj_name, "os") and std.mem.eql(u8, member_name, "env")) {
                func_name = "orbit_os_env";
            } else if (std.mem.eql(u8, obj_name, "os") and std.mem.eql(u8, member_name, "exit")) {
                func_name = "orbit_os_exit";
            } else {
                // Default formatting for module calls if not specially mapped
                func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{obj_name, member_name});
            }
        } else {
            func_name = node.data.call.func.data.identifier.getText(self.source);
            
            if (std.mem.eql(u8, func_name, "ok") and node.data.call.args.len == 1) {
                const val = try self.buildExpr(node.data.call.args[0]);
                var instr = IRInstruction.init(.result_ok);
                instr.operand1 = val;
                const res_reg = try self.current_function.?.allocRegister(self.allocator, .{ .result = null });
                instr.dest = res_reg;
                try self.current_function.?.emit(self.allocator, instr);
                return IRValue{ .register = res_reg };
            } else if (std.mem.eql(u8, func_name, "err")) {
                if (node.data.call.args.len == 1) {
                    const msg = try self.buildExpr(node.data.call.args[0]);
                    var instr = IRInstruction.init(.result_err);
                    instr.operand1 = IRValue{ .int = 500 }; // default code
                    instr.operand2 = msg;
                    const res_reg = try self.current_function.?.allocRegister(self.allocator, .{ .result = null });
                    instr.dest = res_reg;
                    try self.current_function.?.emit(self.allocator, instr);
                    return IRValue{ .register = res_reg };
                } else if (node.data.call.args.len == 2) {
                    const code = try self.buildExpr(node.data.call.args[0]);
                    const msg = try self.buildExpr(node.data.call.args[1]);
                    var instr = IRInstruction.init(.result_err);
                    instr.operand1 = code;
                    instr.operand2 = msg;
                    const res_reg = try self.current_function.?.allocRegister(self.allocator, .{ .result = null });
                    instr.dest = res_reg;
                    try self.current_function.?.emit(self.allocator, instr);
                    return IRValue{ .register = res_reg };
                }
            }
        }

        var instr = IRInstruction.init(.call);
        instr.dest = reg;
        instr.operand1 = IRValue{ .string = func_name };
        instr.operand2 = IRValue{ .int = @intCast(node.data.call.args.len) };
        try self.current_function.?.emit(self.allocator, instr);

        return IRValue{ .register = reg };
    }
    
    fn buildIf(self: *IRBuilder, node: *Node) !void {
        const if_data = node.data.if_stmt;
        const condition = try self.buildExpr(if_data.condition);
        
        const else_label = self.allocLabel();
        const end_label = self.allocLabel();
        
        var branch_instr = IRInstruction.init(.jump_if_false);
        branch_instr.operand1 = condition;
        branch_instr.operand2 = IRValue{ .label = else_label };
        try self.current_function.?.emit(self.allocator, branch_instr);
        
        try self.buildStmt(if_data.then_branch);
        
        var jump_end = IRInstruction.init(.jump);
        jump_end.operand1 = IRValue{ .label = end_label };
        try self.current_function.?.emit(self.allocator, jump_end);
        
        var l_else = IRInstruction.init(.label);
        l_else.operand1 = IRValue{ .label = else_label };
        try self.current_function.?.emit(self.allocator, l_else);
        
        if (if_data.else_branch) |eb| {
            try self.buildStmt(eb);
        }
        
        var l_end = IRInstruction.init(.label);
        l_end.operand1 = IRValue{ .label = end_label };
        try self.current_function.?.emit(self.allocator, l_end);
    }
    
    fn buildWhile(self: *IRBuilder, node: *Node) !void {
        const while_data = node.data.while_stmt;
        const start_label = self.allocLabel();
        const end_label = self.allocLabel();
        
        try self.loop_stack.append(self.allocator, .{ .start_label = start_label, .end_label = end_label });
        defer _ = self.loop_stack.pop();
        
        var l_start = IRInstruction.init(.label);
        l_start.operand1 = IRValue{ .label = start_label };
        try self.current_function.?.emit(self.allocator, l_start);
        
        const condition = try self.buildExpr(while_data.condition);
        
        var branch_instr = IRInstruction.init(.jump_if_false);
        branch_instr.operand1 = condition;
        branch_instr.operand2 = IRValue{ .label = end_label };
        try self.current_function.?.emit(self.allocator, branch_instr);
        
        try self.buildStmt(while_data.body);
        
        var jump_back = IRInstruction.init(.jump);
        jump_back.operand1 = IRValue{ .label = start_label };
        try self.current_function.?.emit(self.allocator, jump_back);
        
        var l_end = IRInstruction.init(.label);
        l_end.operand1 = IRValue{ .label = end_label };
        try self.current_function.?.emit(self.allocator, l_end);
    }

    fn buildMatch(self: *IRBuilder, node: *Node) !void {
        const match_data = node.data.match_stmt;
        const expr_val = try self.buildExpr(match_data.expr);
        const expr_type = self.getNodeType(match_data.expr);
        
        const end_label = self.allocLabel();
        
        // Optimization: Get the tag once if we are matching a Union/Enum
        var tag_reg: ?u32 = null;
        var is_union = expr_type == .tagged_union;
        var is_enum = expr_type == .enumeration;

        if (expr_type == .model) {
            const m_name = expr_type.model;
            for (self.module.types.items) |t| {
                if (std.mem.eql(u8, t.name, m_name)) {
                    if (t.kind == .union_type) is_union = true;
                    if (t.kind == .enumeration) is_enum = true;
                    break;
                }
            }
        }

        if (is_union) {
            tag_reg = try self.current_function.?.allocRegister(self.allocator, .int);
            var get_tag = IRInstruction.init(.union_get_tag);
            get_tag.dest = tag_reg;
            get_tag.operand1 = expr_val;
            try self.current_function.?.emit(self.allocator, get_tag);
        } else if (is_enum) {
            tag_reg = expr_val.register;
        }

        for (match_data.cases) |case| {

            const case_data = case.data.match_case;
            const next_case_label = self.allocLabel();
            
            // Handle pattern comparison
            if (case_data.pattern.tag == .identifier and std.mem.eql(u8, case_data.pattern.data.identifier.getText(self.source), "_")) {
                // Wildcard case - always matches
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.begin_block));
            } else if ((is_union or is_enum) and (case_data.pattern.tag == .member_access or case_data.pattern.tag == .call)) {
                // Union tag comparison
                var ma_node: *Node = case_data.pattern;
                var payload_var: ?ast.Token = null;
                
                if (case_data.pattern.tag == .call) {
                    ma_node = case_data.pattern.data.call.func;
                    if (case_data.pattern.data.call.args.len > 0) {
                        const first_arg = case_data.pattern.data.call.args[0];
                        if (first_arg.tag == .identifier) {
                            payload_var = first_arg.data.identifier;
                        }
                    }
                }
                
                if (ma_node.tag == .member_access) {
                    const ma = ma_node.data.member_access;
                    const obj_name = ma.object.data.identifier.getText(self.source);
                    const member_name = ma.member.getText(self.source);
                    const tag_const_name = try std.fmt.allocPrint(self.allocator, "{s}_TAG_{s}", .{obj_name, member_name});
                    
                    const cmp_reg = try self.current_function.?.allocRegister(self.allocator, .bool);
                    var cmp_instr = IRInstruction.init(.eq);
                    cmp_instr.dest = cmp_reg;
                    cmp_instr.operand1 = IRValue{ .register = tag_reg.? };
                    cmp_instr.operand2 = IRValue{ .symbol = tag_const_name };
                    try self.current_function.?.emit(self.allocator, cmp_instr);
                    
                    var branch_instr = IRInstruction.init(.jump_if_false);
                    branch_instr.operand1 = IRValue{ .register = cmp_reg };
                    branch_instr.operand2 = IRValue{ .label = next_case_label };
                    try self.current_function.?.emit(self.allocator, branch_instr);
                    
                    try self.current_function.?.emit(self.allocator, IRInstruction.init(.begin_block));
                    
                    // If matched and has payload variable, extract it
                    if (payload_var) |v_tok| {
                        var p_type: IRType = .unknown;
                        // Try to find the actual payload type for this variant
                        for (self.module.types.items) |t| {
                            if (std.mem.eql(u8, t.name, obj_name)) {
                                for (t.rich_variants) |rv| {
                                    if (std.mem.eql(u8, rv.name, member_name)) {
                                        if (rv.payload_type) |pt| p_type = pt;
                                        break;
                                    }
                                }
                                break;
                            }
                        }

                        const data_reg = try self.current_function.?.allocRegister(self.allocator, p_type);
                        var get_data = IRInstruction.init(.union_get_data);
                        get_data.dest = data_reg;
                        get_data.operand1 = expr_val;
                        get_data.operand2 = IRValue{ .symbol = tag_const_name };
                        try self.current_function.?.emit(self.allocator, get_data);
                        
                        var decl = IRInstruction.init(.decl_var);
                        decl.operand1 = IRValue{ .string = v_tok.getText(self.source) };
                        decl.operand2 = IRValue{ .register = data_reg };
                        try self.current_function.?.emit(self.allocator, decl);
                        
                        // Register the type for later access (e.g. in print)
                        try self.variable_types.put(v_tok.getText(self.source), p_type);
                    }
                }
            } else {
                // Fallback to simple equality
                const pattern_val = try self.buildExpr(case_data.pattern);
                const reg = try self.current_function.?.allocRegister(self.allocator, .bool);
                var cmp_instr = IRInstruction.init(.eq);
                cmp_instr.dest = reg;
                cmp_instr.operand1 = expr_val;
                cmp_instr.operand2 = pattern_val;
                try self.current_function.?.emit(self.allocator, cmp_instr);
                
                var branch_instr = IRInstruction.init(.jump_if_false);
                branch_instr.operand1 = IRValue{ .register = reg };
                branch_instr.operand2 = IRValue{ .label = next_case_label };
                try self.current_function.?.emit(self.allocator, branch_instr);
                
                try self.current_function.?.emit(self.allocator, IRInstruction.init(.begin_block));
            }
            
            try self.buildStmt(case_data.body);
            try self.current_function.?.emit(self.allocator, IRInstruction.init(.end_block));
            
            var end_jump = IRInstruction.init(.jump);
            end_jump.operand1 = IRValue{ .label = end_label };
            try self.current_function.?.emit(self.allocator, end_jump);
            
            var l_next = IRInstruction.init(.label);
            l_next.operand1 = IRValue{ .label = next_case_label };
            try self.current_function.?.emit(self.allocator, l_next);
        }
        
        var l_end = IRInstruction.init(.label);
        l_end.operand1 = IRValue{ .label = end_label };
        try self.current_function.?.emit(self.allocator, l_end);
    }
    
    fn allocLabel(self: *IRBuilder) u32 {
        const label = self.label_counter;
        self.label_counter += 1;
        return label;
    }

    fn buildAssignment(self: *IRBuilder, node: *Node) anyerror!IRValue {
        const data = node.data.assignment;
        const val = try self.buildExpr(data.value);
        
        if (data.target.tag == .identifier) {
            const name = data.target.data.identifier.getText(self.source);
            var instr = IRInstruction.init(.store_var);
            instr.operand1 = IRValue{ .string = name };
            instr.operand2 = val;
            try self.current_function.?.emit(self.allocator, instr);
            return val;
        } else if (data.target.tag == .member_access) {
            const ma = data.target.data.member_access;
            const obj = try self.buildExpr(ma.object);
            const member_name = ma.member.getText(self.source);
            
            var instr = IRInstruction.init(.store_field);
            instr.operand1 = obj;
            instr.operand2 = IRValue{ .string = member_name };
            instr.operand3 = val;
            try self.current_function.?.emit(self.allocator, instr);
            return val;
        }
        
        return error.InvalidAssignmentTarget;
    }
};
