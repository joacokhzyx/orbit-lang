//! Type inference and compatibility checking for the Orbit semantic analyser.
//! Provides `TypeInfo` (a structured representation of a resolved Orbit type)
//! and `TypeChecker` (the engine that infers expression types, resolves type
//! aliases, registers user-defined kinds, and checks assignment compatibility).

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const Token = @import("../token.zig").Token;
const ModelRegistry = @import("model_registry.zig").ModelRegistry;
const ModuleRegistry = @import("module_registry.zig").ModuleRegistry;

// ─── TypeInfo ────────────────────────────────────────────────────────────────

/// A resolved Orbit type descriptor.  Tracks nullability, collection shape,
/// and whether the type is a `Result<T>` wrapper introduced by Phase 2.
pub const TypeInfo = struct {
    name: []const u8,
    base_type: []const u8,
    is_nullable: bool,
    is_array: bool,
    is_collection: bool,
    is_result: bool, // Phase 2: Result<T, E>
    inner_type: ?[]const u8, // Phase 2: generic inner type

    /// Creates a plain (non-nullable, non-collection) `TypeInfo` whose name
    /// and base type are both set to `name`.
    pub fn init(name: []const u8) TypeInfo {
        return .{
            .name = name,
            .base_type = name,
            .is_nullable = false,
            .is_array = false,
            .is_collection = false,
            .is_result = false,
            .inner_type = null,
        };
    }

    /// Returns a copy of this `TypeInfo` with `is_nullable` set to `true`.
    pub fn makeNullable(self: TypeInfo) TypeInfo {
        var result = self;
        result.is_nullable = true;
        return result;
    }

    /// Returns a copy of this `TypeInfo` marked as an array collection.
    pub fn makeArray(self: TypeInfo) TypeInfo {
        var result = self;
        result.is_array = true;
        result.is_collection = true;
        return result;
    }

    /// Returns a copy of this `TypeInfo` wrapped in a `Result<T>` type,
    /// setting `name` to `"result"` and storing the original name as
    /// `inner_type`.
    pub fn makeResult(self: TypeInfo) TypeInfo {
        var result = self;
        result.is_result = true;
        result.inner_type = self.name;
        result.name = "result";
        return result;
    }

    /// Returns a copy of this `TypeInfo` as a `List<T>` collection.
    pub fn makeList(self: TypeInfo) TypeInfo {
        var result = self;
        result.is_collection = true;
        result.inner_type = self.name;
        result.name = "list";
        return result;
    }

    /// Returns a copy of this `TypeInfo` as a `Map<K, V>` collection.
    pub fn makeMap(self: TypeInfo) TypeInfo {
        var result = self;
        result.is_collection = true;
        result.inner_type = self.name;
        result.name = "map";
        return result;
    }
};

// ─── TypeChecker ─────────────────────────────────────────────────────────────

/// Analyses AST nodes to infer and record their types, resolve aliases, and
/// validate type compatibility.
///
/// The checker is shared across all statements and expressions in a
/// compilation unit.  It writes results into the caller-provided `node_types`
/// map so that the IR builder can look up types by node pointer.
pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    node_types: *std.AutoHashMapUnmanaged(*Node, []const u8),
    type_aliases: std.StringHashMapUnmanaged([]const u8),
    type_kinds: std.StringHashMapUnmanaged(TypeKind), // Phase 2
    union_registry: std.StringHashMapUnmanaged([]const []const u8), // Phase 2
    model_registry: ?*ModelRegistry = null,
    module_registry: ?*ModuleRegistry = null,
    source: []const u8,

    /// Classifies the "shape" of a user-defined type for Phase 2 exhaustiveness
    /// and constructor-call inference.
    pub const TypeKind = enum {
        primitive,
        model,
        enumeration,
        union_type,
        trait_type,
        list_type,
        map_type,
        result_type,
        option_type,
    };

    /// Creates a `TypeChecker` that writes inferred types into `node_types`.
    /// `source` is the full source text of the compilation unit (used for
    /// identifier look-up via token locations).
    pub fn init(allocator: std.mem.Allocator, node_types: *std.AutoHashMapUnmanaged(*Node, []const u8), source: []const u8) TypeChecker {
        return .{
            .allocator = allocator,
            .node_types = node_types,
            .type_aliases = .empty,
            .type_kinds = .empty,
            .union_registry = .empty,
            .source = source,
        };
    }

    /// Releases internal maps owned by the checker.
    pub fn deinit(self: *TypeChecker) void {
        self.type_aliases.deinit(self.allocator);
        self.type_kinds.deinit(self.allocator);
        self.union_registry.deinit(self.allocator);
    }

    // ─── Type registration ────────────────────────────────────────────────

    /// Records a type alias (`name` → `base_type`) so that `resolveType` can
    /// follow the chain during compatibility checks.
    pub fn registerAlias(self: *TypeChecker, name: []const u8, base_type: []const u8) !void {
        try self.type_aliases.put(self.allocator, name, base_type);
    }

    /// Phase 2: Registers a user-defined type's kind (enum, union, trait …)
    /// for constructor-call inference and exhaustiveness checking.
    pub fn registerTypeKind(self: *TypeChecker, name: []const u8, kind: TypeKind) !void {
        try self.type_kinds.put(self.allocator, name, kind);
    }

    /// Phase 2: Records the complete variant list for a union or enum so that
    /// `checkExhaustive` / `getMissingVariant` can verify match coverage.
    pub fn registerUnionVariants(self: *TypeChecker, name: []const u8, variants: []const []const u8) !void {
        try self.union_registry.put(self.allocator, name, variants);
    }

    /// Phase 2: Returns the `TypeKind` registered for `name`, or `null` if
    /// `name` is not a known user-defined type.
    pub fn getTypeKind(self: *TypeChecker, name: []const u8) ?TypeKind {
        return self.type_kinds.get(name);
    }

    // ─── Type resolution ──────────────────────────────────────────────────

    /// Follows the alias chain starting at `type_name` until a base type with
    /// no further alias is reached.  Protects against cycles by breaking when
    /// `current == base`.
    pub fn resolveType(self: *TypeChecker, type_name: []const u8) []const u8 {
        var current = type_name;
        while (self.type_aliases.get(current)) |base| {
            if (std.mem.eql(u8, current, base)) break; // Prevent infinite loop
            current = base;
        }
        return current;
    }

    /// Phase 2: Returns `true` if all variants of `type_name` appear in
    /// `covered_variants` (exhaustive match check).
    pub fn checkExhaustive(self: *TypeChecker, type_name: []const u8, covered_variants: []const []const u8) bool {
        return self.getMissingVariant(type_name, covered_variants) == null;
    }

    /// Phase 2: Returns the name of the first variant of `type_name` that is
    /// absent from `covered_variants`, or `null` if the match is exhaustive.
    /// Unknown types pass conservatively (returns `null`).
    pub fn getMissingVariant(self: *TypeChecker, type_name: []const u8, covered_variants: []const []const u8) ?[]const u8 {
        if (self.union_registry.get(type_name)) |all_variants| {
            for (all_variants) |v| {
                var found = false;
                for (covered_variants) |cv| {
                    if (std.mem.eql(u8, v, cv)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return v;
            }
            return null;
        }
        return null; // Unknown types pass (conservative)
    }

    // ─── Type inference ───────────────────────────────────────────────────

    /// Infers the Orbit type string for `node` given the provided `scope`.
    /// The result is stored in `node_types` (best-effort; allocation errors
    /// are silently ignored) and returned as a slice.
    pub fn inferType(self: *TypeChecker, node: *Node, scope: anytype) []const u8 {
        const inferred = switch (node.tag) {
            .string_literal => "string",
            .integer_literal => "int",
            .char_literal => "int",
            .float_literal => "float",
            .boolean_literal => "bool",
            .identifier => self.inferIdentifierType(node, scope),
            .binary_op => self.inferBinaryOpType(node, scope),
            .call => self.inferCallType(node, scope),
            .member_access => self.inferMemberAccessType(node, scope),
            .field_init => self.inferType(node.data.field_init.value, scope),
            .array_literal => "list", // Phase 2: list, not "array"
            .object_literal => "map", // Phase 2: map
            .type_decl, .enum_decl, .union_decl => "type",
            .assignment => self.inferType(node.data.assignment.value, scope),
            .index_access => blk: {
                const ia = node.data.index_access;
                _ = self.inferType(ia.object, scope);
                _ = self.inferType(ia.index, scope);
                break :blk "unknown"; // Default to unknown instead of int to allow strings
            },
            .unary_op => blk: {
                const u = node.data.unary_op;
                const operand_type = self.inferType(u.operand, scope);
                if (u.op.tag == .Bang) {
                    break :blk "bool";
                }
                break :blk operand_type;
            },
            else => "unknown",
        };

        self.node_types.put(self.allocator, node, inferred) catch {};
        return inferred;
    }

    /// Resolves the type of an identifier node by looking it up in `scope`.
    fn inferIdentifierType(self: *TypeChecker, node: *Node, scope: anytype) []const u8 {
        const name = node.data.identifier.getText(self.source);
        if (scope.get(name)) |entry| {
            return entry.type_name;
        }
        return "unknown";
    }

    /// Infers the result type of a binary operation based on operator and
    /// operand types.  Comparison and logical operators always yield `"bool"`;
    /// arithmetic promotes `int` → `float` when one side is `float`.
    fn inferBinaryOpType(self: *TypeChecker, node: *Node, scope: anytype) []const u8 {
        const bin_data = node.data.binary_op;
        const lhs_type = self.inferType(bin_data.lhs, scope);
        const rhs_type = self.inferType(bin_data.rhs, scope);

        // Comparison operators always return bool
        const op_tag = bin_data.op.tag;
        const is_comparison = (op_tag == .DoubleEqual or op_tag == .NotEqual or
            op_tag == .Less or op_tag == .LessEqual or
            op_tag == .Greater or op_tag == .GreaterEqual);
        if (is_comparison) return "bool";

        // Logical operators also return bool
        if (op_tag == .DoubleAmpersand or op_tag == .DoublePipe) return "bool";

        if (op_tag == .Plus and (std.mem.eql(u8, lhs_type, "string") or std.mem.eql(u8, rhs_type, "string"))) {
            return "string";
        }

        if (std.mem.eql(u8, lhs_type, "int") and std.mem.eql(u8, rhs_type, "int")) {
            return "int";
        }

        if (std.mem.eql(u8, lhs_type, "float") or std.mem.eql(u8, rhs_type, "float")) {
            return "float";
        }

        return "unknown";
    }

    /// Infers the return type of a call expression.  Handles well-known
    /// built-in functions (`ok`, `err`, `print`, `bit_op`), user-defined
    /// functions looked up through `scope`, model constructors, and
    /// standard-module method calls.
    fn inferCallType(self: *TypeChecker, node: *Node, scope: anytype) []const u8 {
        const call_data = node.data.call;

        for (call_data.args) |arg| {
            _ = self.inferType(arg, scope);
        }

        if (call_data.func.tag == .identifier) {
            const func_name = call_data.func.data.identifier.getText(self.source);
            if (std.mem.eql(u8, func_name, "ok")) return "result";
            if (std.mem.eql(u8, func_name, "err")) return "result";
            if (std.mem.eql(u8, func_name, "print")) return "void";
            if (std.mem.eql(u8, func_name, "bit_op")) return "int";

            if (scope.get(func_name)) |entry| {
                if (entry.is_function) return entry.type_name;
            }

            // If it's a model name, it's a constructor call
            if (self.model_registry) |reg| {
                if (reg.getModel(func_name)) |_| {
                    return func_name;
                }
            }

            // Phase 2: Check if it's a known type (enum/union constructor)
            if (self.type_kinds.get(func_name)) |kind| {
                switch (kind) {
                    .enumeration, .union_type => return func_name,
                    else => {},
                }
            }
        } else if (call_data.func.tag == .member_access) {
            const ma = call_data.func.data.member_access;
            if (ma.object.tag == .identifier) {
                const obj = ma.object.data.identifier.getText(self.source);
                const mem = ma.member.getText(self.source);
                if (std.mem.eql(u8, obj, "file") and std.mem.eql(u8, mem, "read")) return "string";
                if (std.mem.eql(u8, obj, "file") and std.mem.eql(u8, mem, "write")) return "bool";
                if (std.mem.eql(u8, obj, "file") and std.mem.eql(u8, mem, "list_dir")) return "list";
                if (std.mem.eql(u8, obj, "os") and std.mem.eql(u8, mem, "exec")) return "string";
                if (std.mem.eql(u8, obj, "os") and std.mem.eql(u8, mem, "env")) return "string";
                if (std.mem.eql(u8, obj, "os") and std.mem.eql(u8, mem, "exit")) return "void";
                // Phase 2: List/Map method inference
                const obj_type = self.inferIdentifierType(ma.object, scope);
                if (std.mem.eql(u8, obj_type, "list")) {
                    if (std.mem.eql(u8, mem, "push")) return "void";
                    if (std.mem.eql(u8, mem, "pop")) return "unknown";
                    if (std.mem.eql(u8, mem, "get")) return "unknown";
                    if (std.mem.eql(u8, mem, "len")) return "int";
                }
                if (std.mem.eql(u8, obj_type, "map")) {
                    if (std.mem.eql(u8, mem, "set")) return "void";
                    if (std.mem.eql(u8, mem, "get")) return "unknown";
                    if (std.mem.eql(u8, mem, "has")) return "bool";
                    if (std.mem.eql(u8, mem, "delete")) return "void";
                    if (std.mem.eql(u8, mem, "keys")) return "list";
                    if (std.mem.eql(u8, mem, "count")) return "int";
                }
                if (std.mem.eql(u8, obj_type, "string")) {
                    if (std.mem.eql(u8, mem, "at")) return "int";
                    if (std.mem.eql(u8, mem, "slice")) return "string";
                }
            }
            return self.inferMemberAccessType(call_data.func, scope);
        }

        return "unknown";
    }

    /// Infers the type of a member-access expression (`obj.member`).
    /// Handles collection members, Result members, string properties, model
    /// field look-up, and module function return types.
    fn inferMemberAccessType(self: *TypeChecker, node: *Node, scope: anytype) []const u8 {
        const member_data = node.data.member_access;
        const obj_type = self.inferType(member_data.object, scope);
        const member_name = member_data.member.getText(self.source);

        if (std.mem.eql(u8, obj_type, "collection") or std.mem.eql(u8, obj_type, "list")) {
            if (std.mem.eql(u8, member_name, "all")) return "list";
            if (std.mem.eql(u8, member_name, "first")) return "object";
            if (std.mem.eql(u8, member_name, "count")) return "int";
            if (std.mem.eql(u8, member_name, "len")) return "int";
            if (std.mem.eql(u8, member_name, "exists")) return "bool";
        }

        if (std.mem.eql(u8, obj_type, "map")) {
            if (std.mem.eql(u8, member_name, "count")) return "int";
        }

        // Phase 2: Result type member access
        if (std.mem.eql(u8, obj_type, "result")) {
            if (std.mem.eql(u8, member_name, "ok")) return "bool";
            if (std.mem.eql(u8, member_name, "value")) return "unknown";
            if (std.mem.eql(u8, member_name, "error_msg")) return "string";
            if (std.mem.eql(u8, member_name, "error_code")) return "int";
        }

        if (std.mem.eql(u8, obj_type, "string")) {
            if (std.mem.eql(u8, member_name, "length")) return "int";
        }

        if (self.model_registry) |reg| {
            if (reg.getField(obj_type, member_name)) |field| {
                return field.type_name;
            }
        }

        if (self.module_registry) |reg| {
            if (reg.getFunction(obj_type, member_name)) |func| {
                return func.return_type;
            }
        }

        // Handle Enum/Model member access (e.g. Status.Active)
        if (member_data.object.tag == .identifier) {
            const name = member_data.object.data.identifier.getText(self.source);
            if (scope.get(name)) |entry| {
                if (std.mem.eql(u8, entry.type_name, "type") or
                    std.mem.eql(u8, entry.type_name, "enum") or
                    std.mem.eql(u8, entry.type_name, "union"))
                {
                    return name;
                }
            }
        }

        return "unknown";
    }

    fn isIntegerType(type_name: []const u8) bool {
        const ints = [_][]const u8{ "int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize", "byte" };
        for (ints) |it| {
            if (std.mem.eql(u8, type_name, it)) return true;
        }
        return false;
    }

    // ─── Compatibility checking ───────────────────────────────────────────

    /// Returns `true` when `actual` is assignable to `expected` after alias
    /// resolution.  The check is intentionally permissive: `"unknown"` on
    /// either side always passes, and `int` is promotable to `float`.
    pub fn checkCompatibility(self: *TypeChecker, expected: []const u8, actual: []const u8) bool {
        const resolved_expected = self.resolveType(expected);
        const resolved_actual = self.resolveType(actual);

        if (std.mem.eql(u8, resolved_expected, resolved_actual)) return true;
        if (std.mem.eql(u8, resolved_expected, "unknown")) return true;
        if (std.mem.eql(u8, resolved_actual, "unknown")) return true;

        // Sized integer / generic int compatibility
        if (isIntegerType(resolved_expected) and isIntegerType(resolved_actual)) {
            if (std.mem.eql(u8, resolved_expected, "int") or std.mem.eql(u8, resolved_actual, "int")) {
                return true;
            }
        }

        // Pointer compatibility: ptr/pointer/mut_ptr/mut_pointer are compatible with void* ("pointer")
        const is_expected_ptr = std.mem.eql(u8, resolved_expected, "pointer") or std.mem.eql(u8, resolved_expected, "ptr") or std.mem.eql(u8, resolved_expected, "mut_pointer") or std.mem.eql(u8, resolved_expected, "mut_ptr");
        const is_actual_ptr = std.mem.eql(u8, resolved_actual, "pointer") or std.mem.eql(u8, resolved_actual, "ptr") or std.mem.eql(u8, resolved_actual, "mut_pointer") or std.mem.eql(u8, resolved_actual, "mut_ptr");
        if (is_expected_ptr and is_actual_ptr) return true;

        // Phase 2: Result<T> is compatible with T (auto-wrap)
        if (std.mem.eql(u8, resolved_expected, "result")) return true;

        // Phase 2: int is promotable to float
        if (std.mem.eql(u8, resolved_expected, "float") and std.mem.eql(u8, resolved_actual, "int")) return true;

        return false;
    }
};
