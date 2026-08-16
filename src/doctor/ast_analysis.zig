//! Orbit Doctor — Layer 2 AST Structural Analyses.
//!
//! Implements the four Layer 2 analyses from ENGINEERING.md §2.4 on a single
//! parsed `.orb` source: cyclomatic complexity, recursive call depth without
//! tail-call optimisation, allocation inside hot loops, and dead function
//! detection. Every analysis consumes the parsed AST directly and emits
//! allocator-owned `ui.Finding` values.

const std = @import("std");
const ui = @import("ui.zig");
const Parser = @import("../parser.zig").Parser;

const category_name = "AST";

/// AST node type produced by `Parser.parse`, derived without a direct import.
const Node = std.meta.Child(@typeInfo(@typeInfo(@TypeOf(Parser.parse)).@"fn".return_type.?).error_union.payload);

const FnDecl = struct {
    name: []const u8,
    name_line: usize,
    body: *Node,
};

const CallGraph = std.StringHashMap(std.ArrayListUnmanaged([]const u8));

/// Runs all Layer 2 AST analyses over one parsed `.orb` source.
///
/// Returns findings owned by `allocator` (caller frees the slice and each
/// message). Parse failures are converted to a `.warning` finding with code
/// `DOC-L2-PARSE` and `analyze` returns normally — it never propagates a
/// parse error.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8) ![]ui.Finding {
    var findings = std.ArrayListUnmanaged(ui.Finding).empty;

    var parser = Parser.init(source, file_path, allocator);
    const root = parser.parse() catch |err| {
        try appendFinding(allocator, &findings, "DOC-L2-PARSE", .warning, file_path, 0, try std.fmt.allocPrint(allocator, "Could not parse {s}: {s}", .{ file_path, @errorName(err) }));
        return findings.toOwnedSlice(allocator);
    };

    const decls = root.data.root.decls;

    var fns = std.ArrayListUnmanaged(FnDecl).empty;
    defer fns.deinit(allocator);
    var routes = std.ArrayListUnmanaged(*Node).empty;
    defer routes.deinit(allocator);
    var schedules = std.ArrayListUnmanaged(*Node).empty;
    defer schedules.deinit(allocator);

    for (decls) |d| {
        switch (d.tag) {
            .fn_decl => {
                const fd = d.data.fn_decl;
                try fns.append(allocator, .{
                    .name = fd.name.text,
                    .name_line = fd.name.loc.line,
                    .body = fd.body,
                });
            },
            .route_decl => try routes.append(allocator, d),
            .schedule_decl => try schedules.append(allocator, d),
            else => {},
        }
    }

    var graph = CallGraph.init(allocator);
    defer deinitCallGraph(allocator, &graph);

    for (fns.items) |f| {
        var callee_list = std.ArrayListUnmanaged([]const u8).empty;
        errdefer callee_list.deinit(allocator);
        try collectCallees(allocator, f.body, &callee_list);
        try graph.put(f.name, callee_list);
    }

    for (fns.items) |f| {
        const n = fnComplexity(f.body);
        if (n > 20) {
            try appendFinding(allocator, &findings, "DOC-L2-001", .err, file_path, f.name_line, try std.fmt.allocPrint(allocator, "Function complexity {d} exceeds safe limit for production code", .{n}));
        } else if (n >= 11) {
            try appendFinding(allocator, &findings, "DOC-L2-001", .warning, file_path, f.name_line, try std.fmt.allocPrint(allocator, "Function complexity {d}: consider extracting sub-functions", .{n}));
        }
    }

    for (fns.items) |f| {
        if (try isRecursive(allocator, &graph, f.name)) {
            if (!isTailRecursive(f.body, f.name)) {
                try appendFinding(allocator, &findings, "DOC-L2-002", .warning, file_path, f.name_line, try std.fmt.allocPrint(allocator, "fn {s} is recursive but not in tail position — may exhaust the call stack under sustained load.", .{f.name}));
            }
        }
    }

    for (fns.items) |f| {
        var loop_ctx = LoopCtx{
            .allocator = allocator,
            .fn_name = f.name,
            .file_path = file_path,
            .depth = 0,
            .findings = &findings,
        };
        try walkLoopAlloc(f.body, &loop_ctx);
    }

    var fn_names = std.StringHashMap(void).init(allocator);
    defer fn_names.deinit();
    for (fns.items) |f| try fn_names.put(f.name, {});

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();

    var seeds = std.ArrayListUnmanaged([]const u8).empty;
    defer seeds.deinit(allocator);
    for (routes.items) |r| try collectCallees(allocator, r.data.route_decl.body, &seeds);
    for (schedules.items) |s| try collectCallees(allocator, s.data.schedule_decl.handler, &seeds);

    var queue = std.ArrayListUnmanaged([]const u8).empty;
    defer queue.deinit(allocator);
    for (seeds.items) |c| {
        if (fn_names.contains(c) and !reachable.contains(c)) {
            try reachable.put(c, {});
            try queue.append(allocator, c);
        }
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const name = queue.items[qi];
        if (graph.get(name)) |callees| {
            for (callees.items) |c| {
                if (fn_names.contains(c) and !reachable.contains(c)) {
                    try reachable.put(c, {});
                    try queue.append(allocator, c);
                }
            }
        }
    }

    for (fns.items) |f| {
        if (!reachable.contains(f.name)) {
            try appendFinding(allocator, &findings, "DOC-L2-004", .warning, file_path, f.name_line, try std.fmt.allocPrint(allocator, "fn {s} is never called from any route or schedule and will not be compiled into the output binary.", .{f.name}));
        }
    }

    return findings.toOwnedSlice(allocator);
}

fn appendFinding(allocator: std.mem.Allocator, findings: *std.ArrayListUnmanaged(ui.Finding), code: []const u8, severity: ui.DiagnosticSeverity, file_path: []const u8, line: usize, message: []const u8) !void {
    try findings.append(allocator, .{
        .category = try allocator.dupe(u8, category_name),
        .code = try allocator.dupe(u8, code),
        .severity = severity,
        .file = try allocator.dupe(u8, file_path),
        .line = line,
        .message = message,
    });
}

fn deinitCallGraph(allocator: std.mem.Allocator, graph: *CallGraph) void {
    var it = graph.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    graph.deinit();
}

fn forEachChild(node: *Node, ctx: anytype, comptime visit: anytype) anyerror!void {
    switch (node.tag) {
        .root => for (node.data.root.decls) |d| try visit(ctx, d),
        .use_stmt => {},
        .import_stmt => {},
        .model_decl => {
            for (node.data.model_decl.generic_params) |g| try visit(ctx, g);
            for (node.data.model_decl.fields) |f| try visit(ctx, f);
        },
        .route_decl => {
            if (node.data.route_decl.params) |ps| {
                for (ps) |p| try visit(ctx, p);
            }
            for (node.data.route_decl.decorators) |d| try visit(ctx, d);
            try visit(ctx, node.data.route_decl.body);
        },
        .fn_decl => {
            for (node.data.fn_decl.generic_params) |g| try visit(ctx, g);
            for (node.data.fn_decl.params) |p| try visit(ctx, p);
            if (node.data.fn_decl.return_type) |rt| try visit(ctx, rt);
            try visit(ctx, node.data.fn_decl.body);
        },
        .role_decl => {
            for (node.data.role_decl.params) |p| try visit(ctx, p);
            try visit(ctx, node.data.role_decl.condition);
        },
        .const_decl => try visit(ctx, node.data.const_decl.value),
        .val_decl => {
            if (node.data.val_decl.value) |v| try visit(ctx, v);
            if (node.data.val_decl.type_annotation) |t| try visit(ctx, t);
        },
        .type_decl => try visit(ctx, node.data.type_decl.target_type),
        .enum_decl => {},
        .union_decl => for (node.data.union_decl.variants) |v| try visit(ctx, v),
        .config_decl => try visit(ctx, node.data.config_decl.value),
        .schedule_decl => try visit(ctx, node.data.schedule_decl.handler),
        .trait_decl => {
            for (node.data.trait_decl.generic_params) |g| try visit(ctx, g);
            for (node.data.trait_decl.methods) |m| try visit(ctx, m);
        },
        .impl_decl => {
            try visit(ctx, node.data.impl_decl.type_expr);
            for (node.data.impl_decl.methods) |m| try visit(ctx, m);
        },
        .block => for (node.data.block.stmts) |s| try visit(ctx, s),
        .expression_stmt => try visit(ctx, node.data.expression_stmt.expr),
        .return_stmt => if (node.data.return_stmt.expr) |e| try visit(ctx, e),
        .return_ok => try visit(ctx, node.data.return_ok.expr),
        .err_stmt => try visit(ctx, node.data.err_stmt.message),
        .err_shortcut => try visit(ctx, node.data.err_shortcut.message),
        .if_stmt => {
            try visit(ctx, node.data.if_stmt.condition);
            try visit(ctx, node.data.if_stmt.then_branch);
            if (node.data.if_stmt.else_branch) |eb| try visit(ctx, eb);
        },
        .match_stmt => {
            try visit(ctx, node.data.match_stmt.expr);
            for (node.data.match_stmt.cases) |c| try visit(ctx, c);
        },
        .match_expr => {
            try visit(ctx, node.data.match_expr.expr);
            for (node.data.match_expr.cases) |c| try visit(ctx, c);
        },
        .for_stmt => {
            try visit(ctx, node.data.for_stmt.iterable);
            try visit(ctx, node.data.for_stmt.body);
        },
        .while_stmt => {
            try visit(ctx, node.data.while_stmt.condition);
            try visit(ctx, node.data.while_stmt.body);
        },
        .loop_stmt => try visit(ctx, node.data.loop_stmt.body),
        .assignment => {
            try visit(ctx, node.data.assignment.target);
            try visit(ctx, node.data.assignment.value);
        },
        .req_block => for (node.data.req_block.fields) |f| try visit(ctx, f),
        .break_stmt => {},
        .continue_stmt => {},
        .binary_op => {
            try visit(ctx, node.data.binary_op.lhs);
            try visit(ctx, node.data.binary_op.rhs);
        },
        .unary_op => try visit(ctx, node.data.unary_op.operand),
        .call => {
            try visit(ctx, node.data.call.func);
            for (node.data.call.args) |a| try visit(ctx, a);
        },
        .member_access => try visit(ctx, node.data.member_access.object),
        .index_access => {
            try visit(ctx, node.data.index_access.object);
            try visit(ctx, node.data.index_access.index);
        },
        .rescue_expr => {
            try visit(ctx, node.data.rescue_expr.expr);
            try visit(ctx, node.data.rescue_expr.message);
        },
        .try_expr => try visit(ctx, node.data.try_expr.expr),
        .null_coalesce => {
            try visit(ctx, node.data.null_coalesce.expr);
            try visit(ctx, node.data.null_coalesce.default);
        },
        .await_expr => try visit(ctx, node.data.await_expr.expr),
        .arrow_fn => try visit(ctx, node.data.arrow_fn.body),
        .identifier => {},
        .string_literal => {},
        .integer_literal => {},
        .float_literal => {},
        .boolean_literal => {},
        .null_literal => {},
        .char_literal => {},
        .array_literal => for (node.data.array_literal.elements) |e| try visit(ctx, e),
        .object_literal => for (node.data.object_literal.fields) |f| try visit(ctx, f),
        .field_decl => {
            if (node.data.field_decl.type_expr) |t| try visit(ctx, t);
            for (node.data.field_decl.decorators) |d| try visit(ctx, d);
            if (node.data.field_decl.default_value) |dv| try visit(ctx, dv);
        },
        .param => if (node.data.param.type_expr) |t| try visit(ctx, t),
        .field_init => try visit(ctx, node.data.field_init.value),
        .decorator => for (node.data.decorator.args) |a| try visit(ctx, a),
        .type_expr => for (node.data.type_expr.generics) |g| try visit(ctx, g),
        .match_case => {
            try visit(ctx, node.data.match_case.pattern);
            try visit(ctx, node.data.match_case.body);
        },
        .union_variant => for (node.data.union_variant.payloads) |p| try visit(ctx, p),
        .generic_param => {},
    }
}

fn matchCases(node: *Node) []const *Node {
    return switch (node.tag) {
        .match_stmt => node.data.match_stmt.cases,
        .match_expr => node.data.match_expr.cases,
        else => unreachable,
    };
}

fn fnComplexity(body: *Node) usize {
    var count: usize = 1;
    walkComplexity(body, &count);
    return count;
}

fn complexityVisit(ctx: *usize, node: *Node) !void {
    walkComplexity(node, ctx);
}

fn walkComplexity(node: *Node, count: *usize) void {
    switch (node.tag) {
        .if_stmt, .while_stmt, .for_stmt, .loop_stmt => count.* += 1,
        .match_stmt, .match_expr => count.* += matchCases(node).len,
        .rescue_expr => count.* += 1,
        else => {},
    }
    forEachChild(node, count, complexityVisit) catch {};
}

const CalleeCtx = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
};

fn collectVisit(ctx: *CalleeCtx, node: *Node) !void {
    if (node.tag == .call) {
        const func = node.data.call.func;
        if (func.tag == .identifier) {
            try ctx.list.append(ctx.allocator, func.data.identifier.text);
        }
    }
    try forEachChild(node, ctx, collectVisit);
}

fn collectCallees(allocator: std.mem.Allocator, node: *Node, list: *std.ArrayListUnmanaged([]const u8)) !void {
    var ctx = CalleeCtx{ .allocator = allocator, .list = list };
    try collectVisit(&ctx, node);
}

const TailCtx = struct {
    name: []const u8,
    ok: bool,
};

fn tailVisit(ctx: *TailCtx, node: *Node) !void {
    if (!isTailRecursive(node, ctx.name)) ctx.ok = false;
}

fn isSelfCall(expr: *Node, name: []const u8) bool {
    if (expr.tag != .call) return false;
    const func = expr.data.call.func;
    if (func.tag != .identifier) return false;
    return std.mem.eql(u8, func.data.identifier.text, name);
}

fn isSelfTailReturn(node: *Node, name: []const u8) bool {
    if (node.tag != .return_stmt) return false;
    const expr = node.data.return_stmt.expr orelse return false;
    return isSelfCall(expr, name);
}

fn isTailRecursive(node: *Node, name: []const u8) bool {
    switch (node.tag) {
        .block => {
            const stmts = node.data.block.stmts;
            if (stmts.len == 0) return false;
            if (!isSelfTailReturn(stmts[stmts.len - 1], name)) return false;
            for (stmts[0 .. stmts.len - 1]) |s| {
                if (!isTailRecursive(s, name)) return false;
            }
            return true;
        },
        .if_stmt => {
            if (!isTailRecursive(node.data.if_stmt.then_branch, name)) return false;
            if (node.data.if_stmt.else_branch) |eb| {
                if (!isTailRecursive(eb, name)) return false;
            }
            return true;
        },
        .match_stmt => {
            for (node.data.match_stmt.cases) |c| {
                if (!isTailRecursive(c, name)) return false;
            }
            return true;
        },
        .match_expr => {
            for (node.data.match_expr.cases) |c| {
                if (!isTailRecursive(c, name)) return false;
            }
            return true;
        },
        .match_case => {
            const body = node.data.match_case.body;
            if (body.tag == .block) return isTailRecursive(body, name);
            return isSelfTailReturn(body, name);
        },
        .for_stmt => return isTailRecursive(node.data.for_stmt.body, name),
        .while_stmt => return isTailRecursive(node.data.while_stmt.body, name),
        .loop_stmt => return isTailRecursive(node.data.loop_stmt.body, name),
        .arrow_fn => {
            const body = node.data.arrow_fn.body;
            if (body.tag == .block) return isTailRecursive(body, name);
            return true;
        },
        else => {
            var ctx = TailCtx{ .name = name, .ok = true };
            forEachChild(node, &ctx, tailVisit) catch return false;
            return ctx.ok;
        },
    }
}

fn isRecursive(allocator: std.mem.Allocator, graph: *const CallGraph, name: []const u8) !bool {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    return dfsReaches(graph, name, name, &visited);
}

fn dfsReaches(graph: *const CallGraph, cur: []const u8, target: []const u8, visited: *std.StringHashMap(void)) bool {
    if (visited.contains(cur)) return false;
    visited.put(cur, {}) catch return false;
    if (graph.get(cur)) |callees| {
        for (callees.items) |c| {
            if (std.mem.eql(u8, c, target)) return true;
            if (dfsReaches(graph, c, target, visited)) return true;
        }
    }
    return false;
}

const Callee = struct {
    name: []const u8,
    line: usize,
};

fn calleeInfo(node: *Node) ?Callee {
    const func = node.data.call.func;
    return switch (func.tag) {
        .identifier => .{ .name = func.data.identifier.text, .line = func.data.identifier.loc.line },
        .member_access => .{ .name = func.data.member_access.member.text, .line = func.data.member_access.member.loc.line },
        else => null,
    };
}

fn isAllocCallee(name: []const u8) bool {
    return std.mem.eql(u8, name, "list_create") or
        std.mem.eql(u8, name, "map_create") or
        std.mem.endsWith(u8, name, "_alloc");
}

const LoopCtx = struct {
    allocator: std.mem.Allocator,
    fn_name: []const u8,
    file_path: []const u8,
    depth: usize,
    findings: *std.ArrayListUnmanaged(ui.Finding),
};

fn loopVisit(ctx: *LoopCtx, node: *Node) !void {
    try walkLoopAlloc(node, ctx);
}

fn walkLoopAlloc(node: *Node, ctx: *LoopCtx) !void {
    switch (node.tag) {
        .for_stmt => {
            try walkLoopAlloc(node.data.for_stmt.iterable, ctx);
            ctx.depth += 1;
            try walkLoopAlloc(node.data.for_stmt.body, ctx);
            ctx.depth -= 1;
        },
        .while_stmt => {
            try walkLoopAlloc(node.data.while_stmt.condition, ctx);
            ctx.depth += 1;
            try walkLoopAlloc(node.data.while_stmt.body, ctx);
            ctx.depth -= 1;
        },
        .call => {
            if (ctx.depth > 0) {
                if (calleeInfo(node)) |callee| {
                    if (isAllocCallee(callee.name)) {
                        try appendFinding(ctx.allocator, ctx.findings, "DOC-L2-003", .warning, ctx.file_path, callee.line, try std.fmt.allocPrint(ctx.allocator, "Allocation inside loop body in fn {s} at {d}. Consider pre-allocating and reusing outside the loop.", .{ ctx.fn_name, callee.line }));
                    }
                }
            }
            try forEachChild(node, ctx, loopVisit);
        },
        else => try forEachChild(node, ctx, loopVisit),
    }
}

test "complexity_warning_emitted_between_11_and_20" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source = try buildComplexitySource(allocator, 11);
    const findings = try analyze(allocator, source, "complex.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-001"));
    const f = getFinding(findings, "DOC-L2-001").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Function complexity 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "consider extracting sub-functions") != null);
}

test "complexity_error_emitted_above_20" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source = try buildComplexitySource(allocator, 21);
    const findings = try analyze(allocator, source, "complex.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-001"));
    const f = getFinding(findings, "DOC-L2-001").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.err, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Function complexity 22") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "exceeds safe limit for production code") != null);
}

test "complexity_counts_match_cases_and_rescue" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn process(x: int, id: int) -> int {
        \\    if x > 0 { return 1 }
        \\    if x > 1 { return 2 }
        \\    if x > 2 { return 3 }
        \\    if x > 3 { return 4 }
        \\    if x > 4 { return 5 }
        \\    if x > 5 { return 6 }
        \\    match x {
        \\        1 => return 10,
        \\        2 => return 20,
        \\        3 => return 30,
        \\        _ => return 0,
        \\    }
        \\    return db.get(id) ? err 404 "missing"
        \\}
    ;
    const findings = try analyze(allocator, source, "complex.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-001"));
    const f = getFinding(findings, "DOC-L2-001").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Function complexity 12") != null);
}

test "clean_function_produces_no_findings" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/" {
        \\    return simple(1)
        \\}
        \\fn simple(a: int) -> int {
        \\    return a + 1
        \\}
    ;
    const findings = try analyze(allocator, source, "clean.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "recursion_without_tco_warns" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn count(n: int) -> int {
        \\    count(n - 1)
        \\    return 0
        \\}
    ;
    const findings = try analyze(allocator, source, "rec.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-002"));
    const f = getFinding(findings, "DOC-L2-002").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "fn count is recursive but not in tail position") != null);
}

test "tail_recursive_function_is_clean" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/down" => down(5)
        \\fn down(n: int) -> int {
        \\    return down(n - 1)
        \\}
    ;
    const findings = try analyze(allocator, source, "rec.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L2-002"));
}

test "mutual_recursion_warns_for_both_functions" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn ping(n: int) -> int {
        \\    return pong(n - 1)
        \\}
        \\fn pong(n: int) -> int {
        \\    return ping(n - 1)
        \\}
    ;
    const findings = try analyze(allocator, source, "rec.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 2), countWithCode(findings, "DOC-L2-002"));
}

test "allocation_in_loop_warns_with_exact_lines" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/render" => render()
        \\fn render(rows: int) {
        \\    for item in rows {
        \\        val b = buffer_alloc(1024)
        \\        map_create()
        \\    }
        \\    while true {
        \\        list_create()
        \\    }
        \\}
    ;
    const findings = try analyze(allocator, source, "loop.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 3), countWithCode(findings, "DOC-L2-003"));
    var found_lines = std.ArrayListUnmanaged(usize).empty;
    defer found_lines.deinit(allocator);
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "DOC-L2-003")) {
            try found_lines.append(allocator, f.line);
        }
    }
    try std.testing.expect(hasLine(found_lines.items, 4));
    try std.testing.expect(hasLine(found_lines.items, 5));
    try std.testing.expect(hasLine(found_lines.items, 8));
    const f = getFinding(findings, "DOC-L2-003").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Allocation inside loop body in fn render at") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Consider pre-allocating and reusing outside the loop.") != null);
}

test "allocation_outside_loop_is_not_reported" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/" => setup()
        \\fn setup() {
        \\    list_create()
        \\    while true {
        \\        break
        \\    }
        \\}
    ;
    const findings = try analyze(allocator, source, "loop.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L2-003"));
}

test "dead_function_warns" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn unused_helper(x: int) -> int {
        \\    return x
        \\}
        \\route GET "/" {
        \\    return 1
        \\}
    ;
    const findings = try analyze(allocator, source, "dead.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-004"));
    const f = getFinding(findings, "DOC-L2-004").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "fn unused_helper is never called from any route or schedule") != null);
}

test "function_reachable_from_route_is_not_dead" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn helper(x: int) -> int {
        \\    a()
        \\    return x
        \\}
        \\fn a() -> int {
        \\    return 42
        \\}
        \\route GET "/" => helper(1)
    ;
    const findings = try analyze(allocator, source, "dead.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L2-004"));
}

test "schedule_reference_keeps_function_alive" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\every 1 hour => cleanup()
        \\fn cleanup() {
        \\    return
        \\}
    ;
    const findings = try analyze(allocator, source, "sched.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L2-004"));
}

test "malformed_source_returns_parse_warning" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn broken() {
        \\    val x = $
        \\}
    ;
    const findings = try analyze(allocator, source, "broken.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L2-PARSE"));
    const f = findings[0];
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 0), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Could not parse broken.orb") != null);
}

fn buildComplexitySource(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    try buf.appendSlice(allocator, "fn heavy(x: int) -> int {\n");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator, "if x > {d} {{ return {d} }}\n", .{ i, i });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    try buf.appendSlice(allocator, "return 0\n}\n");
    return buf.toOwnedSlice(allocator);
}

fn testArena() struct { arena: std.heap.ArenaAllocator } {
    return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
}

fn freeFindings(allocator: std.mem.Allocator, findings: []const ui.Finding) void {
    for (findings) |f| {
        allocator.free(f.category);
        allocator.free(f.code);
        allocator.free(f.file);
        allocator.free(f.message);
    }
    allocator.free(findings);
}

fn countWithCode(findings: []const ui.Finding, code: []const u8) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, code)) n += 1;
    }
    return n;
}

fn getFinding(findings: []const ui.Finding, code: []const u8) ?ui.Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, code)) return f;
    }
    return null;
}

fn hasLine(lines: []const usize, target: usize) bool {
    for (lines) |l| {
        if (l == target) return true;
    }
    return false;
}