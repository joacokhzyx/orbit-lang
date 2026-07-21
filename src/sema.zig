//! Semantic analysis (Sema) pass for the Orbit language.
//!
//! `Sema` performs a multi-pass walk over the AST produced by the parser:
//!   1. Registers type, model, enum, and union declarations.
//!   2. Pre-registers function signatures so forward calls resolve correctly.
//!   3. Analyses top-level constants and variables.
//!   4. Fully analyses function bodies and route handlers.
//!
//! Diagnostics (type mismatches, undefined names, non-exhaustive matches, etc.)
//! are collected in a `DiagnosticReporter` rather than aborting immediately,
//! allowing multiple errors to be reported in a single compiler invocation.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

const TypeChecker = @import("sema/type_checker.zig").TypeChecker;
const ScopeManager = @import("sema/scope_manager.zig").ScopeManager;
const Scope = @import("sema/scope_manager.zig").Scope;
const ModuleRegistry = @import("sema/module_registry.zig").ModuleRegistry;
const ModelRegistry = @import("sema/model_registry.zig").ModelRegistry;
const ModelInfo = @import("sema/model_registry.zig").ModelInfo;
const ModelField = @import("sema/model_registry.zig").ModelField;
const DiagnosticReporter = @import("sema/diagnostic.zig").DiagnosticReporter;

// ─── Error set ────────────────────────────────────────────────────────────────

/// All errors that the semantic analysis phase may return.
pub const SemaError = error{
    TypeMismatch,
    NonExhaustiveMatch,
    UndefinedVariable,
    UndefinedFunction,
    UndefinedModel,
    DuplicateDefinition,
    InvalidOperation,
    MissingReturn,
    InvalidDecorator,
    OutOfMemory,
};

// ─── Sema ─────────────────────────────────────────────────────────────────────

/// Semantic analyser for an Orbit compilation unit.
///
/// Create with `Sema.create`, run `analyze` on the root AST node, inspect
/// `diagnostics` for any errors, then call `deinit` to release all resources.
pub const Sema = struct {
    /// Re-export of the `Diagnostic` type for callers that import `Sema`.
    pub const Diagnostic = @import("sema/diagnostic.zig").Diagnostic;

    allocator: std.mem.Allocator,
    source: []const u8,
    node_types: std.AutoHashMapUnmanaged(*Node, []const u8),
    string_table: std.StringHashMapUnmanaged([]const u8),

    type_checker: TypeChecker,
    scope_manager: ScopeManager,
    module_registry: ModuleRegistry,
    model_registry: ModelRegistry,
    diagnostics: DiagnosticReporter,

    has_server_init: bool,
    current_function_return_type: ?[]const u8,

    /// Heap-allocates and fully initialises a `Sema` instance.
    ///
    /// All sub-components (type checker, scope manager, registries, diagnostics)
    /// are initialised and cross-linked here.  Call `deinit` to free everything.
    pub fn create(allocator: std.mem.Allocator, source: []const u8) !*Sema {
        const self = try allocator.create(Sema);
        self.* = Sema{
            .allocator = allocator,
            .source = source,
            .node_types = .empty,
            .string_table = .empty,
            .type_checker = undefined,
            .scope_manager = ScopeManager.init(allocator),
            .module_registry = ModuleRegistry.init(allocator),
            .model_registry = ModelRegistry.init(allocator),
            .diagnostics = DiagnosticReporter.init(allocator),
            .has_server_init = false,
            .current_function_return_type = null,
        };

        self.type_checker = TypeChecker.init(allocator, &self.node_types, source);
        self.type_checker.model_registry = &self.model_registry;
        self.type_checker.module_registry = &self.module_registry;

        return self;
    }

    /// Returns a de-duplicated, allocator-owned copy of `str`.
    /// Subsequent calls with the same content return the same pointer.
    fn internString(self: *Sema, str: []const u8) ![]const u8 {
        if (self.string_table.get(str)) |interned| {
            return interned;
        }
        const owned = try self.allocator.dupe(u8, str);
        try self.string_table.put(self.allocator, owned, owned);
        return owned;
    }

    /// Releases all memory owned by this `Sema` instance, including the
    /// node-type map, string table, and all sub-components, then frees `self`.
    pub fn deinit(self: *Sema) void {
        self.node_types.deinit(self.allocator);
        var it = self.string_table.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.string_table.deinit(self.allocator);
        self.type_checker.deinit();
        self.scope_manager.deinit();
        self.module_registry.deinit();
        self.model_registry.deinit();
        self.diagnostics.deinit();
        self.allocator.destroy(self);
    }

    // ─── Main entry-point ─────────────────────────────────────────────────────

    /// Runs all four semantic analysis passes over the AST rooted at `root`.
    ///
    /// Pass 1 – type/model/enum/union declarations
    /// Pass 2 – function signatures (enables forward calls)
    /// Pass 3 – top-level constants and variables
    /// Pass 4 – function bodies and route handlers
    pub fn analyze(self: *Sema, root: *Node) !void {
        try self.module_registry.initStandardModules();

        const global_scope = try self.scope_manager.pushScope();

        if (root.tag != .root) return error.NotARootNode;

        // Pass 1: Types, Models, Enums, Unions
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .model_decl, .type_decl, .enum_decl, .union_decl => try self.analyzeDeclaration(decl, global_scope),
                else => {},
            }
        }

        // Pass 2: Function Signatures
        for (root.data.root.decls) |decl| {
            if (decl.tag == .fn_decl) {
                try self.registerFunctionSignature(decl, global_scope);
            }
        }

        // Pass 3: Constants and Variables (Top-level)
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .const_decl, .val_decl => try self.analyzeDeclaration(decl, global_scope),
                else => {},
            }
        }

        // Pass 4: Function Bodies and Routes
        for (root.data.root.decls) |decl| {
            switch (decl.tag) {
                .fn_decl, .route_decl => try self.analyzeDeclaration(decl, global_scope),
                else => {},
            }
        }

        self.scope_manager.popScope();
    }

    // ─── Declaration analysis ─────────────────────────────────────────────────

    /// Dispatches a single declaration node to the appropriate analyser.
    fn analyzeDeclaration(self: *Sema, node: *Node, scope: *Scope) anyerror!void {
        switch (node.tag) {
            .model_decl => try self.analyzeModel(node, scope),
            .route_decl => try self.analyzeRoute(node, scope),
            .fn_decl => try self.analyzeFunction(node, scope),
            .const_decl => try self.analyzeConst(node, scope),
            .val_decl => try self.analyzeVal(node, scope),
            .type_decl => try self.analyzeType(node, scope),
            .enum_decl => try self.analyzeEnum(node, scope),
            .union_decl => try self.analyzeUnion(node, scope),
            .expression_stmt => {
                _ = try self.analyzeExpression(node.data.expression_stmt.expr, scope);
            },
            else => {},
        }
    }

    /// Registers a function's return type in `scope` so that forward calls to
    /// it can be resolved during Pass 4.  Reports a diagnostic on duplicate names.
    fn registerFunctionSignature(self: *Sema, node: *Node, scope: *Scope) !void {
        const fn_data = node.data.fn_decl;
        const fn_name = try self.internString(fn_data.name.getText(self.source));
        const return_type = if (fn_data.return_type) |rt|
            try self.internString(rt.getText(self.source))
        else
            "void";

        scope.defineFunction(fn_name, return_type) catch |err| {
            if (err == error.DuplicateDefinition) {
                const msg = try std.fmt.allocPrint(self.allocator, "Function '{s}' is already defined", .{fn_name});
                try self.diagnostics.reportError("E001", msg, fn_data.name);
            } else {
                return err;
            }
        };
    }

    /// Validates a `model` declaration, registers its fields in `ModelRegistry`,
    /// and defines the model name in `scope` as a `"model"` type.
    fn analyzeModel(self: *Sema, node: *Node, scope: *Scope) !void {
        const model_data = node.data.model_decl;
        const model_name = try self.internString(model_data.name.getText(self.source));

        var fields = std.ArrayListUnmanaged(ModelField).empty;

        for (model_data.fields) |field_node| {
            const field_data = field_node.data.field_decl;
            const field_name = try self.internString(field_data.name.getText(self.source));
            const field_type = try self.internString(field_data.type_name.getText(self.source));

            var is_primary = false;
            var is_unique = false;
            var is_auto = false;

            for (field_data.decorators) |dec| {
                const dec_name = dec.data.decorator.name.getText(self.source);
                if (std.mem.eql(u8, dec_name, "primary")) is_primary = true;
                if (std.mem.eql(u8, dec_name, "unique")) is_unique = true;
                if (std.mem.eql(u8, dec_name, "auto")) is_auto = true;
            }

            const field = ModelField{
                .name = field_name,
                .type_name = field_type,
                .is_primary = is_primary,
                .is_unique = is_unique,
                .is_auto = is_auto,
                .decorators = &[_][]const u8{},
            };

            try fields.append(self.allocator, field);
        }

        const model_info = ModelInfo{
            .name = model_name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .table_name = model_name,
        };

        try self.model_registry.register(model_info);
        try scope.define(model_name, "model", false);
    }

    /// Analyses a `route` declaration, creating a child scope that pre-defines
    /// `req` and `res` and setting the expected return type to `"response"`.
    fn analyzeRoute(self: *Sema, node: *Node, scope: *Scope) !void {
        _ = scope;
        self.has_server_init = true;

        const route_data = node.data.route_decl;
        const route_scope = try self.scope_manager.pushScope();

        try route_scope.define("req", "request", false);
        try route_scope.define("res", "response", false);

        const previous_return_type = self.current_function_return_type;
        self.current_function_return_type = "response";
        defer self.current_function_return_type = previous_return_type;

        if (route_data.body.tag == .block) {
            for (route_data.body.data.block.stmts) |stmt| {
                try self.analyzeStatement(stmt, route_scope);
            }
        } else {
            try self.analyzeStatement(route_data.body, route_scope);
        }

        self.scope_manager.popScope();
    }

    /// Analyses a function body in a fresh scope, with parameters pre-defined.
    /// The expected return type is set for the duration of the body walk.
    fn analyzeFunction(self: *Sema, node: *Node, scope: *Scope) !void {
        _ = scope;

        const fn_data = node.data.fn_decl;
        const return_type = if (fn_data.return_type) |rt|
            try self.internString(rt.getText(self.source))
        else
            "void";

        // Function signature was already registered in Pass 2.

        const fn_scope = try self.scope_manager.pushScope();

        for (fn_data.params) |param| {
            const param_data = param.data.param;
            const param_name = try self.internString(param_data.name.getText(self.source));
            const param_type = if (param_data.type_name) |tn|
                try self.internString(tn.getText(self.source))
            else
                "unknown";

            try fn_scope.define(param_name, param_type, false);
        }

        const previous_return_type = self.current_function_return_type;
        self.current_function_return_type = return_type;
        defer self.current_function_return_type = previous_return_type;

        if (fn_data.body.tag == .block) {
            for (fn_data.body.data.block.stmts) |stmt| {
                try self.analyzeStatement(stmt, fn_scope);
            }
        } else {
            try self.analyzeStatement(fn_data.body, fn_scope);
        }

        self.scope_manager.popScope();
    }

    /// Infers the type of a `const` declaration's value and registers the name
    /// in `scope` as immutable.
    fn analyzeConst(self: *Sema, node: *Node, scope: *Scope) !void {
        const const_data = node.data.const_decl;
        const name = const_data.name.getText(self.source);
        const value_type = try self.analyzeExpression(const_data.value, scope);

        try scope.define(name, value_type, false);
    }

    /// Infers the type of a `val` declaration, validates any explicit type
    /// annotation, and registers the binding in `scope`.
    fn analyzeVal(self: *Sema, node: *Node, scope: *Scope) !void {
        const val_data = node.data.val_decl;
        const name = try self.internString(val_data.name.getText(self.source));

        var final_type: []const u8 = "unknown";

        if (val_data.value) |value| {
            final_type = try self.analyzeExpression(value, scope);
        }

        if (val_data.type_annotation) |type_ann| {
            const ann_type = try self.internString(type_ann.data.type_annotation.base.getText(self.source));
            if (!std.mem.eql(u8, final_type, "unknown") and !self.type_checker.checkCompatibility(ann_type, final_type)) {
                return error.TypeMismatch;
            }
            final_type = ann_type;
        }

        try scope.define(name, final_type, val_data.is_mut);
    }

    // ─── Statement analysis ───────────────────────────────────────────────────

    /// Dispatches a single statement node to the appropriate analyser.
    fn analyzeStatement(self: *Sema, node: *Node, scope: *Scope) anyerror!void {
        switch (node.tag) {
            .block => {
                const block_scope = try self.scope_manager.pushScope();
                for (node.data.block.stmts) |stmt| {
                    try self.analyzeStatement(stmt, block_scope);
                }
                self.scope_manager.popScope();
            },
            .expression_stmt => {
                _ = try self.analyzeExpression(node.data.expression_stmt.expr, scope);
            },
            .return_stmt => {
                try self.analyzeReturn(node, scope);
            },
            .val_decl => try self.analyzeVal(node, scope),
            .if_stmt => try self.analyzeIf(node, scope),
            .for_stmt => try self.analyzeFor(node, scope),
            .while_stmt => try self.analyzeWhile(node, scope),
            .match_stmt => try self.analyzeMatch(node, scope),
            else => {},
        }
    }

    /// Validates a `return` statement against the enclosing function's declared
    /// return type, reporting type-mismatch or missing-value diagnostics.
    fn analyzeReturn(self: *Sema, node: *Node, scope: *Scope) !void {
        const expected_type = self.current_function_return_type orelse "void";

        if (node.data.return_stmt.expr) |value| {
            const actual_type = try self.analyzeExpression(value, scope);
            if (std.mem.eql(u8, expected_type, "void")) {
                const tok = self.getNodeToken(value);
                try self.diagnostics.reportError("return/unexpected-value", "Void function cannot return a value", tok);
                return error.TypeMismatch;
            }
            if (!self.type_checker.checkCompatibility(expected_type, actual_type)) {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "Return type mismatch: expected '{s}', got '{s}'",
                    .{ expected_type, actual_type },
                );
                const tok = self.getNodeToken(value);
                try self.diagnostics.reportError("return/type-mismatch", message, tok);
                return error.TypeMismatch;
            }
            return;
        }

        if (!std.mem.eql(u8, expected_type, "void")) {
            const tok = self.getNodeToken(node);
            try self.diagnostics.reportError("return/missing-value", "Non-void function must return a value", tok);
            return error.MissingReturn;
        }
    }

    /// Analyses an `if` statement, creating separate child scopes for the
    /// then-branch and the optional else-branch.
    fn analyzeIf(self: *Sema, node: *Node, scope: *Scope) !void {
        const if_data = node.data.if_stmt;

        _ = try self.analyzeExpression(if_data.condition, scope);

        const then_scope = try self.scope_manager.pushScope();
        if (if_data.then_branch.tag == .block) {
            for (if_data.then_branch.data.block.stmts) |stmt| {
                try self.analyzeStatement(stmt, then_scope);
            }
        } else {
            try self.analyzeStatement(if_data.then_branch, then_scope);
        }
        self.scope_manager.popScope();

        if (if_data.else_branch) |else_branch| {
            const else_scope = try self.scope_manager.pushScope();
            if (else_branch.tag == .block) {
                for (else_branch.data.block.stmts) |stmt| {
                    try self.analyzeStatement(stmt, else_scope);
                }
            } else {
                try self.analyzeStatement(else_branch, else_scope);
            }
            self.scope_manager.popScope();
        }
    }

    /// Analyses a `for item in iterable` loop, binding `item` in a fresh scope.
    fn analyzeFor(self: *Sema, node: *Node, scope: *Scope) !void {
        const for_data = node.data.for_stmt;

        _ = try self.analyzeExpression(for_data.iterable, scope);

        const for_scope = try self.scope_manager.pushScope();

        const iterator_name = try self.internString(for_data.item.getText(self.source));
        try for_scope.define(iterator_name, "unknown", false);

        if (for_data.body.tag == .block) {
            for (for_data.body.data.block.stmts) |stmt| {
                try self.analyzeStatement(stmt, for_scope);
            }
        } else {
            try self.analyzeStatement(for_data.body, for_scope);
        }

        self.scope_manager.popScope();
    }

    /// Analyses a `while condition { body }` loop.
    fn analyzeWhile(self: *Sema, node: *Node, scope: *Scope) !void {
        const while_data = node.data.while_stmt;

        _ = try self.analyzeExpression(while_data.condition, scope);

        const while_scope = try self.scope_manager.pushScope();
        if (while_data.body.tag == .block) {
            for (while_data.body.data.block.stmts) |stmt| {
                try self.analyzeStatement(stmt, while_scope);
            }
        } else {
            try self.analyzeStatement(while_data.body, while_scope);
        }
        self.scope_manager.popScope();
    }

    /// Analyses a `match` expression, tracking covered variants and reporting a
    /// diagnostic when a match on an enum or union type is non-exhaustive.
    fn analyzeMatch(self: *Sema, node: *Node, scope: *Scope) !void {
        const match_data = node.data.match_stmt;
        const match_type = try self.analyzeExpression(match_data.expr, scope);

        var covered_variants = std.ArrayListUnmanaged([]const u8).empty;
        defer covered_variants.deinit(self.allocator);
        var has_wildcard = false;

        for (match_data.cases) |case| {
            const case_data = case.data.match_case;
            const case_scope = try self.scope_manager.pushScope();

            _ = try self.analyzeExpression(case_data.pattern, case_scope);

            if (self.isWildcardPattern(case_data.pattern)) {
                has_wildcard = true;
            } else if (self.extractPatternVariant(case_data.pattern)) |variant| {
                try covered_variants.append(self.allocator, variant);
            }

            try self.analyzeStatement(case_data.body, case_scope);

            self.scope_manager.popScope();
        }

        if (!has_wildcard) {
            if (self.type_checker.getTypeKind(match_type)) |kind| {
                if ((kind == .enumeration or kind == .union_type)) {
                    if (self.type_checker.getMissingVariant(match_type, covered_variants.items)) |missing| {
                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "Non-exhaustive match for type '{s}'. Missing variant: '{s}'",
                            .{ match_type, missing },
                        );
                        defer self.allocator.free(message);

                        const tok = self.getNodeToken(match_data.expr);
                        try self.diagnostics.reportError("match/non-exhaustive", message, tok);
                        return error.NonExhaustiveMatch;
                    }
                }
            }
        }
    }

    // ─── Pattern helpers ──────────────────────────────────────────────────────

    /// Returns `true` if `pattern` is the wildcard identifier `_`.
    fn isWildcardPattern(self: *Sema, pattern: *Node) bool {
        return pattern.tag == .identifier and std.mem.eql(u8, pattern.data.identifier.getText(self.source), "_");
    }

    /// Extracts the variant name string from a match-case pattern node, or
    /// returns `null` for wildcards and unrecognised pattern shapes.
    fn extractPatternVariant(self: *Sema, pattern: *Node) ?[]const u8 {
        switch (pattern.tag) {
            .member_access => {
                return pattern.data.member_access.member.getText(self.source);
            },
            .call => {
                const call_data = pattern.data.call;
                if (call_data.func.tag == .member_access) {
                    return call_data.func.data.member_access.member.getText(self.source);
                }
                return null;
            },
            .identifier => {
                const text = pattern.data.identifier.getText(self.source);
                if (std.mem.eql(u8, text, "_")) return null;
                return text;
            },
            else => return null,
        }
    }

    /// Returns a representative `Token` for `node`, used to attach source
    /// locations to diagnostics.  Falls back to a synthetic invalid token for
    /// node kinds that do not carry a primary token.
    fn getNodeToken(self: *Sema, node: *Node) Token {
        return switch (node.tag) {
            .identifier => node.data.identifier,
            .string_literal => node.data.string_literal,
            .char_literal => node.data.char_literal,
            .integer_literal => node.data.integer_literal,
            .float_literal => node.data.float_literal,
            .boolean_literal => node.data.boolean_literal,
            .member_access => node.data.member_access.member,
            .call => self.getNodeToken(node.data.call.func),
            else => .{
                .tag = .Invalid,
                .loc = .{ .start = 0, .end = 0, .line = 1, .col = 1 },
                .text = "",
                .file_path = "",
                .file_source = "",
            },
        };
    }

    // ─── Type / enum / union analysis ─────────────────────────────────────────

    /// Analyses a `type Name = Target` alias declaration and registers the alias
    /// in the type checker so it can be resolved during expression inference.
    fn analyzeType(self: *Sema, node: *Node, scope: *Scope) !void {
        const type_data = node.data.type_decl;
        const name = try self.internString(type_data.name.getText(self.source));
        const target_type = try self.analyzeExpression(type_data.target_type, scope);

        try self.type_checker.registerAlias(name, target_type);
        try scope.define(name, "type", false);
    }

    /// Analyses an `enum` declaration, registering the type kind and all variant
    /// names in `scope` with the enum's type name as their type.
    fn analyzeEnum(self: *Sema, node: *Node, scope: *Scope) !void {
        const enum_data = node.data.enum_decl;
        const name = try self.internString(enum_data.name.getText(self.source));

        try scope.define(name, "type", false);

        try self.type_checker.registerTypeKind(name, .enumeration);

        var variant_names = std.ArrayListUnmanaged([]const u8).empty;
        for (enum_data.variants) |v| {
            const v_name = try self.internString(v.getText(self.source));
            try scope.define(v_name, name, false);
            try variant_names.append(self.allocator, v_name);
        }

        try self.type_checker.registerUnionVariants(name, try variant_names.toOwnedSlice(self.allocator));
    }

    /// Analyses a `union` declaration, registering the type kind and all variant
    /// names in `scope` with the union's type name as their type.
    fn analyzeUnion(self: *Sema, node: *Node, scope: *Scope) !void {
        const union_data = node.data.union_decl;
        const name = try self.internString(union_data.name.getText(self.source));

        try scope.define(name, "union", false);

        try self.type_checker.registerTypeKind(name, .union_type);

        var variant_names = std.ArrayListUnmanaged([]const u8).empty;
        for (union_data.variants) |v| {
            const v_tk = if (v.tag == .union_variant) v.data.union_variant.name else v.data.identifier;
            const v_name = try self.internString(v_tk.getText(self.source));
            try scope.define(v_name, name, false);
            try variant_names.append(self.allocator, v_name);
        }

        try self.type_checker.registerUnionVariants(name, try variant_names.toOwnedSlice(self.allocator));
    }

    // ─── Expression analysis ──────────────────────────────────────────────────

    /// Infers the type of `node` via the `TypeChecker`, stores the result in the
    /// `node_types` map, and returns the inferred type string.
    fn analyzeExpression(self: *Sema, node: *Node, scope: *Scope) anyerror![]const u8 {
        const expr_type = self.type_checker.inferType(node, scope);
        try self.node_types.put(self.allocator, node, expr_type);
        return expr_type;
    }
};
