//! Orbit Doctor — Layer 3 Semantic Analyses.
//!
//! Implements the three Layer 3 analyses from ENGINEERING.md §2.5 over a fully
//! compiled `.orb` source: unguarded mutable shared state, taint propagation
//! from HTTP request inputs into database operations, and arena leak
//! detection. Every analysis runs after Parser → Sema → IRBuilder, honouring
//! the contract that Layer 3 "requires invoking `src/sema.zig` and
//! `src/ir/builder.zig`". Findings are computed over the AST so every finding
//! carries a precise 1-based source line (the IR carries no source locations).

const std = @import("std");
const ui = @import("ui.zig");
const ast = @import("../ast.zig");
const Node = ast.Node;
const Parser = @import("../parser.zig").Parser;
const Sema = @import("../sema.zig").Sema;
const IRBuilder = @import("../ir/builder.zig").IRBuilder;
const ModelRegistry = @import("../sema/model_registry.zig").ModelRegistry;

const category_name = "Semantic";

/// Runs all Layer 3 semantic analyses over one `.orb` source.
///
/// Returns findings owned by `allocator` (caller frees the slice and each
/// string). Parse/sema/IR failures are converted to a `.warning` finding and
/// `analyze` returns normally — it never propagates a compiler error.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8) ![]ui.Finding {
    var findings = std.ArrayListUnmanaged(ui.Finding).empty;

    var parser = Parser.init(source, file_path, allocator);
    const root = parser.parse() catch |err| {
        return appendAndReturn(allocator, &findings, "DOC-L3-PARSE", file_path, 0, try std.fmt.allocPrint(allocator, "Could not parse {s}: {s}", .{ file_path, @errorName(err) }));
    };

    var sema = Sema.create(allocator, source) catch |err| {
        return appendAndReturn(allocator, &findings, "DOC-L3-SEMA", file_path, 0, try std.fmt.allocPrint(allocator, "Semantic analysis failed for {s}: {s}", .{ file_path, @errorName(err) }));
    };
    defer sema.deinit();

    sema.analyze(root) catch |err| {
        return appendAndReturn(allocator, &findings, "DOC-L3-SEMA", file_path, 0, try std.fmt.allocPrint(allocator, "Semantic analysis failed for {s}: {s}", .{ file_path, @errorName(err) }));
    };

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    _ = builder.build(root) catch |err| {
        return appendAndReturn(allocator, &findings, "DOC-L3-SEMA", file_path, 0, try std.fmt.allocPrint(allocator, "IR construction failed for {s}: {s}", .{ file_path, @errorName(err) }));
    };

    try analyzeSharedState(allocator, root, file_path, &findings);
    try analyzeTaint(allocator, root, file_path, &findings);
    try analyzeArenaLeaks(allocator, root, file_path, &findings, &sema.model_registry);

    return findings.toOwnedSlice(allocator);
}

fn appendAndReturn(allocator: std.mem.Allocator, findings: *std.ArrayListUnmanaged(ui.Finding), code: []const u8, file_path: []const u8, line: usize, message: []const u8) ![]ui.Finding {
    try appendFinding(allocator, findings, code, .warning, file_path, line, message);
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

// ─── DOC-L3-001: Unguarded Mutable Shared State ─────────────────────────────

fn analyzeSharedState(allocator: std.mem.Allocator, root: *Node, file_path: []const u8, findings: *std.ArrayListUnmanaged(ui.Finding)) !void {
    var mutable = std.StringHashMap(void).init(allocator);
    defer mutable.deinit();

    for (root.data.root.decls) |d| {
        if (d.tag == .val_decl and d.data.val_decl.is_mut) {
            try mutable.put(d.data.val_decl.name.text, {});
        }
    }
    if (mutable.count() == 0) return;

    var ctx = StoreCtx{
        .allocator = allocator,
        .file_path = file_path,
        .mutable = &mutable,
        .findings = findings,
    };

    for (root.data.root.decls) |d| {
        switch (d.tag) {
            .route_decl => try walkStore(d.data.route_decl.body, &ctx),
            .schedule_decl => try walkStore(d.data.schedule_decl.handler, &ctx),
            else => {},
        }
    }
}

const StoreCtx = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    mutable: *std.StringHashMap(void),
    findings: *std.ArrayListUnmanaged(ui.Finding),
};

fn storeVisit(ctx: *StoreCtx, node: *Node) anyerror!void {
    if (node.tag == .assignment) {
        const target = node.data.assignment.target;
        if (target.tag == .identifier and ctx.mutable.contains(target.data.identifier.text)) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Module-level mutable variable '{s}' written from concurrent handler without synchronisation. This is a data race.", .{target.data.identifier.text});
            try appendFinding(ctx.allocator, ctx.findings, "DOC-L3-001", .err, ctx.file_path, target.data.identifier.loc.line, msg);
        }
    }
    try forEachChild(node, ctx, storeVisit);
}

fn walkStore(node: *Node, ctx: *StoreCtx) !void {
    try storeVisit(ctx, node);
}

// ─── DOC-L3-002: Taint Propagation for HTTP Inputs ──────────────────────────

const FuncLike = struct {
    node: *Node,
    body: *Node,
    params: []const *Node,
};

const CallRecord = struct {
    callee: []const u8,
    arg_index: usize,
    source: []const u8,
};

const TaintCtx = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    findings: *std.ArrayListUnmanaged(ui.Finding),
    env: *std.StringHashMap(?[]const u8),
    report_sinks: bool,
    records: *std.ArrayListUnmanaged(CallRecord),
    fn_by_name: *std.StringHashMap(*Node),
};

fn analyzeTaint(allocator: std.mem.Allocator, root: *Node, file_path: []const u8, findings: *std.ArrayListUnmanaged(ui.Finding)) !void {
    var funcs = std.ArrayListUnmanaged(FuncLike).empty;
    defer funcs.deinit(allocator);

    var fn_by_name = std.StringHashMap(*Node).init(allocator);
    defer fn_by_name.deinit();

    for (root.data.root.decls) |d| {
        switch (d.tag) {
            .fn_decl => {
                try fn_by_name.put(d.data.fn_decl.name.text, d);
                try funcs.append(allocator, .{
                    .node = d,
                    .body = d.data.fn_decl.body,
                    .params = d.data.fn_decl.params,
                });
            },
            .route_decl => try funcs.append(allocator, .{
                .node = d,
                .body = d.data.route_decl.body,
                .params = &.{},
            }),
            .schedule_decl => try funcs.append(allocator, .{
                .node = d,
                .body = d.data.schedule_decl.handler,
                .params = &.{},
            }),
            else => {},
        }
    }
    if (funcs.items.len == 0) return;

    var param_sources = std.AutoHashMap(*Node, std.ArrayListUnmanaged(?[]const u8)).init(allocator);
    defer {
        var it = param_sources.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        param_sources.deinit();
    }
    for (funcs.items) |f| {
        var list = std.ArrayListUnmanaged(?[]const u8).empty;
        try list.appendNTimes(allocator, null, f.params.len);
        try param_sources.put(f.node, list);
    }

    // Fixpoint: propagate taint from call sites into callee parameters until no
    // new parameter becomes tainted (bounded to stay fast on malformed graphs).
    const max_iterations = funcs.items.len + 1;
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var changed = false;
        var records = std.ArrayListUnmanaged(CallRecord).empty;
        defer records.deinit(allocator);

        for (funcs.items) |f| {
            var env = std.StringHashMap(?[]const u8).init(allocator);
            defer env.deinit();
            if (param_sources.getPtr(f.node)) |slots| try seedEnv(&env, f.params, slots);
            var ctx = TaintCtx{
                .allocator = allocator,
                .file_path = file_path,
                .findings = findings,
                .env = &env,
                .report_sinks = false,
                .records = &records,
                .fn_by_name = &fn_by_name,
            };
            try walkTaintBody(&ctx, f.body);
        }

        for (records.items) |rec| {
            const callee = fn_by_name.get(rec.callee) orelse continue;
            const slots = param_sources.getPtr(callee).?;
            if (rec.arg_index < slots.items.len) {
                if (slots.items[rec.arg_index] == null) {
                    slots.items[rec.arg_index] = rec.source;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }

    // Final pass: emit sink findings using the converged parameter taint.
    for (funcs.items) |f| {
        var env = std.StringHashMap(?[]const u8).init(allocator);
        defer env.deinit();
        if (param_sources.getPtr(f.node)) |slots| try seedEnv(&env, f.params, slots);
        var empty_records = std.ArrayListUnmanaged(CallRecord).empty;
        defer empty_records.deinit(allocator);
        var ctx = TaintCtx{
            .allocator = allocator,
            .file_path = file_path,
            .findings = findings,
            .env = &env,
            .report_sinks = true,
            .records = &empty_records,
            .fn_by_name = &fn_by_name,
        };
        try walkTaintBody(&ctx, f.body);
    }
}

/// Seeds the taint environment from the given parameter sources, mapping each
/// tainted parameter slot to its declared name so the body's variable lookups
/// resolve correctly.
fn seedEnv(env: *std.StringHashMap(?[]const u8), params: []const *Node, sources: *const std.ArrayListUnmanaged(?[]const u8)) !void {
    for (params, 0..) |p, i| {
        if (p.tag == .param) {
            if (i < sources.items.len) {
                if (sources.items[i]) |src| {
                    try env.put(p.data.param.name.text, src);
                }
            }
        }
    }
}

fn walkTaintBody(ctx: *TaintCtx, body: *Node) anyerror!void {
    try walkStmt(ctx, body);
}

fn walkStmts(ctx: *TaintCtx, stmts: []const *Node) anyerror!void {
    for (stmts) |s| try walkStmt(ctx, s);
}

fn walkStmt(ctx: *TaintCtx, node: *Node) anyerror!void {
    switch (node.tag) {
        .block => try walkStmts(ctx, node.data.block.stmts),
        .expression_stmt => _ = try exprTaint(ctx, node.data.expression_stmt.expr),
        .val_decl => {
            const vd = node.data.val_decl;
            if (vd.value) |val| {
                const src = try exprTaint(ctx, val);
                if (src) |s| {
                    try ctx.env.put(vd.name.text, s);
                } else {
                    _ = ctx.env.remove(vd.name.text);
                }
            }
        },
        .const_decl => {
            const src = try exprTaint(ctx, node.data.const_decl.value);
            if (src) |s| {
                try ctx.env.put(node.data.const_decl.name.text, s);
            } else {
                _ = ctx.env.remove(node.data.const_decl.name.text);
            }
        },
        .assignment => {
            const asn = node.data.assignment;
            const src = try exprTaint(ctx, asn.value);
            if (asn.target.tag == .identifier) {
                if (src) |s| {
                    try ctx.env.put(asn.target.data.identifier.text, s);
                } else {
                    _ = ctx.env.remove(asn.target.data.identifier.text);
                }
            }
        },
        .return_stmt => {
            if (node.data.return_stmt.expr) |e| _ = try exprTaint(ctx, e);
        },
        .return_ok => _ = try exprTaint(ctx, node.data.return_ok.expr),
        .err_stmt => _ = try exprTaint(ctx, node.data.err_stmt.message),
        .err_shortcut => _ = try exprTaint(ctx, node.data.err_shortcut.message),
        .if_stmt => {
            const i = node.data.if_stmt;
            _ = try exprTaint(ctx, i.condition);
            try walkStmt(ctx, i.then_branch);
            if (i.else_branch) |eb| try walkStmt(ctx, eb);
        },
        .for_stmt => {
            const f = node.data.for_stmt;
            _ = try exprTaint(ctx, f.iterable);
            try walkStmt(ctx, f.body);
        },
        .while_stmt => {
            const w = node.data.while_stmt;
            _ = try exprTaint(ctx, w.condition);
            try walkStmt(ctx, w.body);
        },
        .loop_stmt => try walkStmt(ctx, node.data.loop_stmt.body),
        .match_stmt => {
            _ = try exprTaint(ctx, node.data.match_stmt.expr);
            for (node.data.match_stmt.cases) |c| try walkStmt(ctx, c);
        },
        .match_expr => {
            _ = try exprTaint(ctx, node.data.match_expr.expr);
            for (node.data.match_expr.cases) |c| try walkStmt(ctx, c);
        },
        .match_case => try walkStmt(ctx, node.data.match_case.body),
        .break_stmt, .continue_stmt => {},
        .req_block => {
            for (node.data.req_block.fields) |f| _ = try exprTaint(ctx, f);
        },
        else => _ = try exprTaint(ctx, node),
    }
}

fn exprTaint(ctx: *TaintCtx, node: *Node) anyerror!?[]const u8 {
    switch (node.tag) {
        .identifier => return ctx.env.get(node.data.identifier.text) orelse null,
        .string_literal, .integer_literal, .float_literal, .boolean_literal, .null_literal, .char_literal => return null,
        .member_access => {
            const ma = node.data.member_access;
            if (ma.object.tag == .identifier and std.mem.eql(u8, ma.object.data.identifier.text, "req")) {
                return ma.member.text;
            }
            return exprTaint(ctx, ma.object);
        },
        .call => return callTaint(ctx, node),
        .binary_op => {
            const b = node.data.binary_op;
            if (try exprTaint(ctx, b.lhs)) |s| return s;
            return exprTaint(ctx, b.rhs);
        },
        .unary_op => return exprTaint(ctx, node.data.unary_op.operand),
        .index_access => {
            const ia = node.data.index_access;
            if (try exprTaint(ctx, ia.object)) |s| return s;
            return exprTaint(ctx, ia.index);
        },
        .array_literal => {
            for (node.data.array_literal.elements) |e| {
                if (try exprTaint(ctx, e)) |s| return s;
            }
            return null;
        },
        .object_literal => {
            for (node.data.object_literal.fields) |f| {
                if (try exprTaint(ctx, f)) |s| return s;
            }
            return null;
        },
        .rescue_expr => {
            const r = node.data.rescue_expr;
            if (try exprTaint(ctx, r.expr)) |s| return s;
            return exprTaint(ctx, r.message);
        },
        .try_expr => return exprTaint(ctx, node.data.try_expr.expr),
        .null_coalesce => {
            const nc = node.data.null_coalesce;
            if (try exprTaint(ctx, nc.expr)) |s| return s;
            return exprTaint(ctx, nc.default);
        },
        .await_expr => return exprTaint(ctx, node.data.await_expr.expr),
        .field_init => return exprTaint(ctx, node.data.field_init.value),
        .arrow_fn => return null,
        else => return null,
    }
}

fn callTaint(ctx: *TaintCtx, node: *Node) anyerror!?[]const u8 {
    const call = node.data.call;
    const func = call.func;
    const args = call.args;

    if (func.tag == .member_access) {
        const ma = func.data.member_access;
        const member = ma.member.text;
        if (ma.object.tag == .identifier) {
            const obj = ma.object.data.identifier.text;
            if (std.mem.eql(u8, obj, "req")) {
                return reqFieldSource(node, member);
            }
            const arg_src = try firstTaintedArg(ctx, args);
            if (isDbSink(obj, member)) {
                if (arg_src) |s| try reportSink(ctx, node, s);
                return null;
            }
            if (isSanitizer(member)) return null;
            return arg_src;
        }
        return firstTaintedArg(ctx, args);
    }

    if (func.tag == .identifier) {
        const name = func.data.identifier.text;
        if (ctx.fn_by_name.contains(name)) {
            const arg_srcs = try taintedArgs(ctx, args);
            defer ctx.allocator.free(arg_srcs);
            for (arg_srcs, 0..) |src, i| {
                if (src) |s| try ctx.records.append(ctx.allocator, .{
                    .callee = name,
                    .arg_index = i,
                    .source = s,
                });
            }
            return firstOf(arg_srcs);
        }
        const arg_src = try firstTaintedArg(ctx, args);
        if (isBareDbSink(name)) {
            if (arg_src) |s| try reportSink(ctx, node, s);
            return null;
        }
        if (isSanitizer(name)) return null;
        return arg_src;
    }

    return firstTaintedArg(ctx, args);
}

fn reqFieldSource(call_node: *Node, member: []const u8) []const u8 {
    for (call_node.data.call.args) |a| {
        if (a.tag == .string_literal) return stripQuotes(a.data.string_literal.text);
    }
    return member;
}

fn firstTaintedArg(ctx: *TaintCtx, args: []const *Node) anyerror!?[]const u8 {
    for (args) |a| {
        if (try exprTaint(ctx, a)) |s| return s;
    }
    return null;
}

fn taintedArgs(ctx: *TaintCtx, args: []const *Node) anyerror![]?[]const u8 {
    const out = try ctx.allocator.alloc(?[]const u8, args.len);
    for (args, 0..) |a, i| {
        out[i] = try exprTaint(ctx, a);
    }
    return out;
}

fn firstOf(sources: []const ?[]const u8) ?[]const u8 {
    for (sources) |s| {
        if (s) |v| return v;
    }
    return null;
}

fn isDbSink(obj: []const u8, member: []const u8) bool {
    if (std.mem.eql(u8, obj, "db")) {
        const db_ops = [_][]const u8{ "get", "set", "where", "all", "insert", "delete", "exec", "query" };
        for (db_ops) |op| {
            if (std.mem.eql(u8, member, op)) return true;
        }
        return false;
    }
    if (obj.len > 0 and std.ascii.isUpper(obj[0])) {
        const model_ops = [_][]const u8{ "all", "where", "find", "get", "create", "insert", "delete" };
        for (model_ops) |op| {
            if (std.mem.eql(u8, member, op)) return true;
        }
    }
    return false;
}

fn isBareDbSink(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "orbit_db_");
}

fn isSanitizer(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "validate") != null or
        std.mem.indexOf(u8, name, "check") != null or
        std.mem.indexOf(u8, name, "sanitize") != null or
        std.mem.indexOf(u8, name, "parse") != null;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn reportSink(ctx: *TaintCtx, node: *Node, source: []const u8) !void {
    if (!ctx.report_sinks) return;
    const line = callLine(node);
    const msg = try std.fmt.allocPrint(ctx.allocator, "Untrusted request field '{s}' flows into database operation at {s}:{d} without validation. Possible injection risk.", .{ source, ctx.file_path, line });
    try appendFinding(ctx.allocator, ctx.findings, "DOC-L3-002", .err, ctx.file_path, line, msg);
}

fn callLine(node: *Node) usize {
    const func = node.data.call.func;
    return switch (func.tag) {
        .member_access => func.data.member_access.member.loc.line,
        .identifier => func.data.identifier.loc.line,
        else => 0,
    };
}

// ─── DOC-L3-003: Arena Leak Detection ───────────────────────────────────────

fn analyzeArenaLeaks(allocator: std.mem.Allocator, root: *Node, file_path: []const u8, findings: *std.ArrayListUnmanaged(ui.Finding), model_registry: *const ModelRegistry) !void {
    var fn_names = std.StringHashMap(void).init(allocator);
    defer fn_names.deinit();

    var graph = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = graph.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        graph.deinit();
    }

    for (root.data.root.decls) |d| {
        if (d.tag == .fn_decl) {
            const name = d.data.fn_decl.name.text;
            try fn_names.put(name, {});
            var callees = std.ArrayListUnmanaged([]const u8).empty;
            errdefer callees.deinit(allocator);
            try collectCallees(allocator, d.data.fn_decl.body, &callees);
            try graph.put(name, callees);
        }
    }

    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();

    var queue = std.ArrayListUnmanaged([]const u8).empty;
    defer queue.deinit(allocator);

    for (root.data.root.decls) |d| {
        switch (d.tag) {
            .route_decl => try seedReachable(allocator, d.data.route_decl.body, &fn_names, &reachable, &queue),
            .schedule_decl => try seedReachable(allocator, d.data.schedule_decl.handler, &fn_names, &reachable, &queue),
            else => {},
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

    for (root.data.root.decls) |d| {
        if (d.tag != .fn_decl) continue;
        const name = d.data.fn_decl.name.text;
        if (reachable.contains(name)) continue;

        var alloc_ctx = AllocCtx{
            .allocator = allocator,
            .file_path = file_path,
            .fn_name = name,
            .findings = findings,
            .model_registry = model_registry,
        };
        try walkAllocs(d.data.fn_decl.body, &alloc_ctx);
    }
}

fn seedReachable(allocator: std.mem.Allocator, body: *Node, fn_names: *std.StringHashMap(void), reachable: *std.StringHashMap(void), queue: *std.ArrayListUnmanaged([]const u8)) !void {
    var callees = std.ArrayListUnmanaged([]const u8).empty;
    defer callees.deinit(allocator);
    try collectCallees(allocator, body, &callees);
    for (callees.items) |c| {
        if (fn_names.contains(c) and !reachable.contains(c)) {
            try reachable.put(c, {});
            try queue.append(allocator, c);
        }
    }
}

const AllocCtx = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    fn_name: []const u8,
    findings: *std.ArrayListUnmanaged(ui.Finding),
    model_registry: *const ModelRegistry,
};

fn allocVisit(ctx: *AllocCtx, node: *Node) anyerror!void {
    if (node.tag == .call and node.data.call.func.tag == .identifier) {
        const name = node.data.call.func.data.identifier.text;
        if (isAllocationCallee(ctx.model_registry, name)) {
            const line = node.data.call.func.data.identifier.loc.line;
            const msg = try std.fmt.allocPrint(ctx.allocator, "Possible unfreed allocation in fn {s} at {s}:{d}. Verify this is covered by an arena scope.", .{ ctx.fn_name, ctx.file_path, line });
            try appendFinding(ctx.allocator, ctx.findings, "DOC-L3-003", .warning, ctx.file_path, line, msg);
        }
    }
    try forEachChild(node, ctx, allocVisit);
}

fn walkAllocs(node: *Node, ctx: *AllocCtx) !void {
    try allocVisit(ctx, node);
}

fn isAllocationCallee(model_registry: *const ModelRegistry, name: []const u8) bool {
    if (model_registry.getModel(name) != null) return true;
    if (std.mem.eql(u8, name, "alloc")) return true;
    if (std.mem.eql(u8, name, "list_create")) return true;
    if (std.mem.eql(u8, name, "map_create")) return true;
    return std.mem.endsWith(u8, name, "_alloc");
}

// ─── Generic AST traversal ──────────────────────────────────────────────────

fn collectCallees(allocator: std.mem.Allocator, node: *Node, list: *std.ArrayListUnmanaged([]const u8)) !void {
    var ctx = CalleeCtx{ .allocator = allocator, .list = list };
    try collectVisit(&ctx, node);
}

const CalleeCtx = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
};

fn collectVisit(ctx: *CalleeCtx, node: *Node) anyerror!void {
    if (node.tag == .call and node.data.call.func.tag == .identifier) {
        try ctx.list.append(ctx.allocator, node.data.call.func.data.identifier.text);
    }
    try forEachChild(node, ctx, collectVisit);
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

// ─── Tests ──────────────────────────────────────────────────────────────────

test "l3.shared_state: mutable module var written from route is a data race" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\val mut counter = 0
        \\route POST "/inc" {
        \\    counter = counter + 1
        \\    return ok 200 counter
        \\}
    ;
    const findings = try analyze(allocator, source, "race.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L3-001"));
    const f = getFinding(findings, "DOC-L3-001").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.err, f.severity);
    try std.testing.expectEqual(@as(usize, 3), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Module-level mutable variable 'counter'") != null);
}

test "l3.shared_state: private mutable helper is not flagged" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\val mut counter = 0
        \\fn bump() {
        \\    counter = counter + 1
        \\}
    ;
    const findings = try analyze(allocator, source, "race.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L3-001"));
}

test "l3.taint: req query parameter flows into model where" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/v1/catalog" {
        \\    val category = req.query("category")
        \\    if (category != "") {
        \\        val filtered = Product.where("category = ?", category)
        \\        return ok 200 filtered
        \\    }
        \\}
    ;
    const findings = try analyze(allocator, source, "catalog.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L3-002"));
    const f = getFinding(findings, "DOC-L3-002").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.err, f.severity);
    try std.testing.expectEqual(@as(usize, 4), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Untrusted request field 'category'") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Possible injection risk") != null);
}

test "l3.taint: req body flows into model create" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route POST "/v1/catalog/items" {
        \\    val body = req.body()
        \\    val created = Product.create(body)
        \\    return ok 201 created
        \\}
    ;
    const findings = try analyze(allocator, source, "create.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L3-002"));
    const f = getFinding(findings, "DOC-L3-002").?;
    try std.testing.expectEqual(@as(usize, 3), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Untrusted request field 'body'") != null);
}

test "l3.taint: literal-only db query is clean" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/v1/catalog/featured" {
        \\    val featured = Product.where("rating >= 4.8")
        \\    return ok 200 featured
        \\}
    ;
    const findings = try analyze(allocator, source, "clean.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L3-002"));
}

test "l3.taint: sanitised request input is not flagged" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/v1/catalog/items" {
        \\    val raw = req.query("category")
        \\    val safe = validate_input(raw)
        \\    val items = Product.where("category = ?", safe)
        \\    return ok 200 items
        \\}
    ;
    const findings = try analyze(allocator, source, "safe.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L3-002"));
}

test "l3.taint: taint flows through helper call parameters" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/v1/search" {
        \\    val q = req.query("q")
        \\    return ok 200 lookup(q)
        \\}
        \\fn lookup(query: string) -> string {
        \\    val results = Product.where("name = ?", query)
        \\    return results
        \\}
    ;
    const findings = try analyze(allocator, source, "interproc.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L3-002"));
    const f = getFinding(findings, "DOC-L3-002").?;
    try std.testing.expectEqual(@as(usize, 6), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Untrusted request field 'q'") != null);
}

test "l3.arena: allocation in main is not arena-scoped" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn main() {
        \\    val buffer = buffer_alloc(1024)
        \\    print(buffer)
        \\}
    ;
    const findings = try analyze(allocator, source, "main.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 1), countWithCode(findings, "DOC-L3-003"));
    const f = getFinding(findings, "DOC-L3-003").?;
    try std.testing.expectEqual(ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 2), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Possible unfreed allocation in fn main") != null);
}

test "l3.arena: allocation in handler-reachable helper is covered" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/" {
        \\    return ok 200 render()
        \\}
        \\fn render() -> string {
        \\    val b = buffer_alloc(64)
        \\    return b
        \\}
    ;
    const findings = try analyze(allocator, source, "handler.orb");
    defer freeFindings(allocator, findings);

    try std.testing.expectEqual(@as(usize, 0), countWithCode(findings, "DOC-L3-003"));
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