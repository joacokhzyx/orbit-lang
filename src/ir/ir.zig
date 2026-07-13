//! orbit/src/ir/ir.zig
//!
//! Defines the Orbit Intermediate Representation (IR) data types:
//! `IROpcode`, `IRValue`, `IRInstruction`, `IRFunction`, `IRModule`, and `IRModel`.
//! All IR types are plain tagged unions / structs with no arena ownership;
//! lifetime is managed by the caller (`IRBuilder`).

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

pub const IROpcode = enum {
    nop,
    load_const,
    load_var,
    store_var,
    decl_var,
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    not_op,
    neg,
    begin_block,
    end_block,
    call,
    ret,
    jump,
    jump_if_false,
    alloc,
    free,
    db_get,
    db_set,
    db_all,
    db_where,
    http_response,
    label,
    copy,
    arg,
    load_field,
    store_field,
    switch_op,
    type_info,

    // ── Phase 2: Collection opcodes ───────────────────────────────
    list_create, // dest = list_create(elem_size, initial_cap)
    list_push, // list_push(list_reg, value_reg)
    list_get, // dest = list_get(list_reg, index)
    list_set, // list_set(list_reg, index, value_reg)
    list_len, // dest = list_len(list_reg)
    map_create, // dest = map_create(value_size)
    map_set, // map_set(map_reg, key_str, value_reg)
    map_get, // dest = map_get(map_reg, key_str)
    map_has, // dest = map_has(map_reg, key_str)
    map_delete, // map_delete(map_reg, key_str)
    map_keys, // dest = map_keys(map_reg)

    // ── Phase 2: Result opcodes ───────────────────────────────────
    result_ok, // dest = result_ok(value_reg)
    result_err, // dest = result_err(code, msg)
    result_unwrap, // dest = unwrap(result_reg) — may branch on error
    result_is_ok, // dest = result.ok (bool)

    // ── Phase 2: Union opcodes ────────────────────────────────────
    union_create, // dest = union_create(tag, data_reg)
    union_get_tag, // dest = union.tag
    union_get_data, // dest = union_get_data(union_reg, expected_tag)
};

pub const IRValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8, // Raw identifier, not quoted
    bool: bool,
    register: u32,
    label: u32,
    none,
};

pub const IRInstruction = struct {
    opcode: IROpcode,
    dest: ?u32,
    operand1: IRValue,
    operand2: IRValue,
    operand3: IRValue,

    pub fn init(opcode: IROpcode) IRInstruction {
        return .{
            .opcode = opcode,
            .dest = null,
            .operand1 = .none,
            .operand2 = .none,
            .operand3 = .none,
        };
    }

    pub fn call(dest: u32, func: []const u8, params: []const IRValue) IRInstruction {
        var instr = IRInstruction.init(.call);
        instr.dest = dest;
        instr.operand1 = IRValue{ .string = func };
        instr.operand2 = IRValue{ .register = @intCast(params.len) };
        instr.operand3 = IRValue{ .register = @intCast(params.len) };
        return instr;
    }
};

/// Phase 2: Extended type system with collections, result, and traits.
pub const IRType = union(enum) {
    int,
    float,
    string,
    bool,
    void,
    unknown,
    response,
    model: []const u8,
    enumeration: []const u8,

    // ── Phase 2 types ─────────────────────────────────────────────
    list: ?*const IRType, // List<T> — inner type if known
    map: ?*const IRType, // Map<string, V> — value type if known
    result: ?*const IRType, // Result<T, E> — ok type if known
    option: ?*const IRType, // Option<T> — inner type if known
    tagged_union: []const u8, // union Name — by name
    trait_obj: []const u8, // interface Name — by name
    slice: ?*const IRType, // Slice<T> — element type

    pub fn fromString(s: []const u8) IRType {
        if (std.mem.eql(u8, s, "int")) return .int;
        if (std.mem.eql(u8, s, "float")) return .float;
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "bool")) return .bool;
        if (std.mem.eql(u8, s, "void")) return .void;
        if (std.mem.eql(u8, s, "response")) return .response;
        if (std.mem.eql(u8, s, "object")) return .response;
        // Phase 2 types from string annotations
        if (std.mem.eql(u8, s, "list")) return .{ .list = null };
        if (std.mem.eql(u8, s, "map")) return .{ .map = null };
        if (std.mem.eql(u8, s, "result")) return .{ .result = null };
        if (std.mem.eql(u8, s, "option")) return .{ .option = null };
        if (std.mem.eql(u8, s, "array")) return .{ .list = null };
        if (s.len > 0 and std.ascii.isUpper(s[0])) return .{ .model = s };
        return .unknown;
    }

    /// Returns true if this is a collection type (List, Map, Slice)
    pub fn isCollection(self: IRType) bool {
        return switch (self) {
            .list, .map, .slice => true,
            else => false,
        };
    }

    /// Returns true if this type uses arena-backed memory at runtime
    pub fn isArenaAllocated(self: IRType) bool {
        return switch (self) {
            .list, .map, .slice, .result, .option, .tagged_union, .trait_obj, .model, .response => true,
            else => false,
        };
    }
};

pub const IRFunction = struct {
    name: []const u8,
    params: []const []const u8,
    param_types: []const IRType, // Phase 2: typed parameters
    instructions: std.ArrayListUnmanaged(IRInstruction),
    register_count: u32,
    register_types: std.ArrayListUnmanaged(IRType),
    return_type: IRType, // Phase 2: explicit return type
    route_info: ?struct {
        method: []const u8,
        path: []const u8,
    },

    pub fn init(allocator: std.mem.Allocator, name: []const u8) IRFunction {
        _ = allocator;
        return .{
            .name = name,
            .params = &.{},
            .param_types = &.{},
            .instructions = .empty,
            .register_count = 0,
            .register_types = .empty,
            .return_type = .void,
            .route_info = null,
        };
    }

    pub fn deinit(self: *IRFunction, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.register_types.deinit(allocator);
    }

    pub fn allocRegister(self: *IRFunction, allocator: std.mem.Allocator, type_val: IRType) !u32 {
        try self.register_types.append(allocator, type_val);
        const reg = self.register_count;
        self.register_count += 1;
        return reg;
    }

    pub fn emit(self: *IRFunction, allocator: std.mem.Allocator, instr: IRInstruction) !void {
        try self.instructions.append(allocator, instr);
    }
};

pub const IRModel = struct {
    name: []const u8,
    fields: std.ArrayListUnmanaged(IRField),

    pub const IRField = struct {
        name: []const u8,
        type_name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8) IRModel {
        _ = allocator;
        return .{
            .name = name,
            .fields = .empty,
        };
    }

    pub fn deinit(self: *IRModel, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }
};

/// Phase 2: Union variants can carry associated data.
pub const IRVariant = struct {
    name: []const u8,
    payload_type: ?IRType, // null = no payload (enum-like), concrete = data variant
    fields: []const VariantField,

    pub const VariantField = struct {
        name: []const u8,
        type_info: IRType,
    };
};

pub const IRTypeDecl = struct {
    name: []const u8,
    kind: enum { enumeration, union_type, alias, trait },
    variants: []const []const u8, // Names of variants or types
    rich_variants: []const IRVariant, // Phase 2: typed variant info
    methods: []const IRTraitMethod, // Phase 2: interface methods

    pub const IRTraitMethod = struct {
        name: []const u8,
        params: []const IRType,
        return_type: IRType,
    };

    pub fn deinit(self: *IRTypeDecl, allocator: std.mem.Allocator) void {
        for (self.variants) |v| {
            allocator.free(v);
        }
        allocator.free(self.variants);
    }
};

pub const IRModule = struct {
    functions: std.ArrayListUnmanaged(IRFunction),
    globals: std.StringHashMapUnmanaged(IRValue),
    models: std.ArrayListUnmanaged(IRModel),
    types: std.ArrayListUnmanaged(IRTypeDecl),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IRModule {
        return .{
            .functions = .empty,
            .globals = .empty,
            .models = .empty,
            .types = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IRModule) void {
        for (self.functions.items) |*func| {
            func.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);

        for (self.models.items) |*mod| {
            mod.deinit(self.allocator);
        }
        self.models.deinit(self.allocator);

        for (self.types.items) |*t| {
            t.deinit(self.allocator);
        }
        self.types.deinit(self.allocator);

        self.globals.deinit(self.allocator);
    }

    pub fn addFunction(self: *IRModule, func: IRFunction) !void {
        try self.functions.append(self.allocator, func);
    }

    pub fn addGlobal(self: *IRModule, name: []const u8, value: IRValue) !void {
        try self.globals.put(self.allocator, name, value);
    }

    pub fn addModel(self: *IRModule, model: IRModel) !void {
        try self.models.append(self.allocator, model);
    }

    /// Phase 2: Find a type declaration by name.
    pub fn findType(self: *const IRModule, name: []const u8) ?*const IRTypeDecl {
        for (self.types.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
};
