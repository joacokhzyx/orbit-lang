const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;

var z3_available: ?bool = null;
var z3_path: []const u8 = "";

pub fn isAvailable() bool {
    if (z3_available) |avail| return avail;
    z3_available = findZ3();
    return z3_available.?;
}

fn findZ3() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();

    const searches = [_][]const u8{ "z3", "z3.exe", "/usr/bin/z3", "/usr/local/bin/z3", "/opt/homebrew/bin/z3" };
    for (searches) |cmd| {
        const result = std.process.run(allocator, io, .{ .argv = &.{ cmd, "--version" } }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) {
            z3_path = cmd;
            return true;
        }
    }
    return false;
}

pub fn verifyEquivalence(allocator: std.mem.Allocator, original: []const IRInstruction, transformed: []const IRInstruction) !bool {
    if (!isAvailable()) return false;

    const smt = try encodeEquivalenceQuery(allocator, original, transformed);
    defer allocator.free(smt);

    return try runZ3(allocator, smt);
}

fn getResultReg(instructions: []const IRInstruction) ?u32 {
    if (instructions.len > 0) {
        const last = instructions[instructions.len - 1];
        if (last.opcode == .ret and last.operand1 == .register) {
            return last.operand1.register;
        }
    }
    var last: ?u32 = null;
    for (instructions) |instr| {
        if (instr.dest) |d| {
            if (producesValue(instr.opcode)) last = d;
        }
    }
    return last;
}

fn producesValue(op: IROpcode) bool {
    return switch (op) {
        .load_const, .load_var, .copy, .add, .sub, .mul, .div, .mod, .and_op, .or_op, .eq, .ne, .lt, .le, .gt, .ge, .neg, .not_op => true,
        else => false,
    };
}

fn encodeEquivalenceQuery(allocator: std.mem.Allocator, a: []const IRInstruction, b: []const IRInstruction) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    var def_a = std.AutoHashMap(u32, usize).init(allocator);
    defer def_a.deinit();
    var def_b = std.AutoHashMap(u32, usize).init(allocator);
    defer def_b.deinit();
    for (a, 0..) |instr, i| {
        if (instr.dest) |d| {
            if (producesValue(instr.opcode)) try def_a.put(d, i);
        }
    }
    for (b, 0..) |instr, i| {
        if (instr.dest) |d| {
            if (producesValue(instr.opcode)) try def_b.put(d, i);
        }
    }

    var inputs = std.AutoHashMap(u32, void).init(allocator);
    defer inputs.deinit();
    try collectInputRegs(a, &def_a, &inputs);
    try collectInputRegs(b, &def_b, &inputs);

    try appendFmt(allocator, &buf, "(set-logic QF_BV)\n(set-option :produce-models false)\n\n", .{});

    try buf.appendSlice(allocator, "; symbolic vars\n");
    for (a) |instr| {
        if (instr.opcode == .load_var) {
            try appendFmt(allocator, &buf, "(declare-fun {s} () (_ BitVec 64))\n", .{instr.operand1.string});
        }
    }
    for (b) |instr| {
        if (instr.opcode == .load_var) {
            if (!alreadyDeclared(a, instr.operand1.string)) {
                try appendFmt(allocator, &buf, "(declare-fun {s} () (_ BitVec 64))\n", .{instr.operand1.string});
            }
        }
    }

    var input_list: std.ArrayListUnmanaged(u32) = .empty;
    defer input_list.deinit(allocator);
    var input_it = inputs.iterator();
    while (input_it.next()) |entry| {
        try input_list.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(u32, input_list.items, {}, comptime std.sort.asc(u32));
    for (input_list.items) |r| {
        try appendFmt(allocator, &buf, "(declare-fun r{d}_in () (_ BitVec 64))\n", .{r});
    }

    try buf.appendSlice(allocator, "\n; orig\n");
    try encodeSeq(allocator, &buf, a, "_orig", &def_a);

    try buf.appendSlice(allocator, "\n; trans\n");
    try encodeSeq(allocator, &buf, b, "_trans", &def_b);

    const result_reg = getResultReg(a) orelse return error.NoDestReg;

    try buf.appendSlice(allocator, "\n(assert (not (= ");
    try encResult(allocator, &buf, result_reg, "_orig", &def_a);
    try buf.appendSlice(allocator, " ");
    try encResult(allocator, &buf, result_reg, "_trans", &def_b);
    try buf.appendSlice(allocator, ")))\n(check-sat)\n");

    return buf.toOwnedSlice(allocator);
}

fn collectInputRegs(instructions: []const IRInstruction, def_map: *std.AutoHashMap(u32, usize), inputs: *std.AutoHashMap(u32, void)) !void {
    for (instructions) |instr| {
        inline for (.{ instr.operand1, instr.operand2, instr.operand3 }) |op| {
            if (op == .register) {
                if (!def_map.contains(op.register)) {
                    try inputs.put(op.register, {});
                }
            }
        }
    }
}

fn encResult(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), reg: u32, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize)) !void {
    if (def_map.get(reg)) |idx| {
        try appendFmt(allocator, buf, "d{d}_{s}", .{ idx, suffix });
    } else {
        try appendFmt(allocator, buf, "r{d}_in", .{reg});
    }
}

fn alreadyDeclared(instructions: []const IRInstruction, name: []const u8) bool {
    for (instructions) |instr| {
        if (instr.opcode == .load_var and std.mem.eql(u8, instr.operand1.string, name)) return true;
    }
    return false;
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn encodeSeq(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), instructions: []const IRInstruction, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize)) !void {
    for (instructions, 0..) |instr, i| {
        try encInstr(allocator, buf, instr, i, suffix, def_map);
    }
}

fn encInstr(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), instr: IRInstruction, index: usize, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize)) !void {
    if (!producesValue(instr.opcode)) return;
    const dn = try std.fmt.allocPrint(allocator, "d{d}_{s}", .{ index, suffix });
    defer allocator.free(dn);

    switch (instr.opcode) {
        .load_const => {
            var v: u64 = 0;
            if (instr.operand1 == .int) {
                v = @bitCast(instr.operand1.int);
            } else if (instr.operand1 == .bool) {
                v = if (instr.operand1.bool) 1 else 0;
            } else if (instr.operand1 == .float) {
                v = @bitCast(instr.operand1.float);
            }
            try appendFmt(allocator, buf, "(define-fun {s} () (_ BitVec 64) #x{x:0>16})\n", .{ dn, v });
        },
        .copy => {
            try buf.appendSlice(allocator, "(define-fun ");
            try buf.appendSlice(allocator, dn);
            try buf.appendSlice(allocator, " () (_ BitVec 64) ");
            try encVal(allocator, buf, instr.operand1, suffix, def_map);
            try buf.appendSlice(allocator, ")\n");
        },
        .load_var => {
            try appendFmt(allocator, buf, "(define-fun {s} () (_ BitVec 64) {s})\n", .{ dn, instr.operand1.string });
        },
        .add => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvadd"),
        .sub => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvsub"),
        .mul => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvmul"),
        .div => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvsdiv"),
        .mod => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvsrem"),
        .and_op => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvand"),
        .or_op => try encBin(allocator, buf, dn, instr, suffix, def_map, "bvor"),
        .eq => try encCmp(allocator, buf, dn, instr, suffix, def_map, "="),
        .ne => try encCmp(allocator, buf, dn, instr, suffix, def_map, "distinct"),
        .lt => try encCmp(allocator, buf, dn, instr, suffix, def_map, "bvslt"),
        .le => try encCmp(allocator, buf, dn, instr, suffix, def_map, "bvsle"),
        .gt => try encCmp(allocator, buf, dn, instr, suffix, def_map, "bvsgt"),
        .ge => try encCmp(allocator, buf, dn, instr, suffix, def_map, "bvsge"),
        .neg => {
            try buf.appendSlice(allocator, "(define-fun ");
            try buf.appendSlice(allocator, dn);
            try buf.appendSlice(allocator, " () (_ BitVec 64) (bvneg ");
            try encVal(allocator, buf, instr.operand1, suffix, def_map);
            try buf.appendSlice(allocator, "))\n");
        },
        .not_op => {
            try buf.appendSlice(allocator, "(define-fun ");
            try buf.appendSlice(allocator, dn);
            try buf.appendSlice(allocator, " () (_ BitVec 64) (bvnot ");
            try encVal(allocator, buf, instr.operand1, suffix, def_map);
            try buf.appendSlice(allocator, "))\n");
        },
        else => {},
    }
}

fn encBin(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dn: []const u8, instr: IRInstruction, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize), op: []const u8) !void {
    try buf.appendSlice(allocator, "(define-fun ");
    try buf.appendSlice(allocator, dn);
    try buf.appendSlice(allocator, " () (_ BitVec 64) (");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand1, suffix, def_map);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand2, suffix, def_map);
    try buf.appendSlice(allocator, "))\n");
}

fn encCmp(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dn: []const u8, instr: IRInstruction, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize), op: []const u8) !void {
    try buf.appendSlice(allocator, "(define-fun ");
    try buf.appendSlice(allocator, dn);
    try buf.appendSlice(allocator, " () (_ BitVec 64) (ite (");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand1, suffix, def_map);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand2, suffix, def_map);
    try buf.appendSlice(allocator, ") #x0000000000000001 #x0000000000000000))\n");
}

fn encVal(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: IRValue, suffix: []const u8, def_map: *std.AutoHashMap(u32, usize)) !void {
    switch (val) {
        .register => |r| {
            if (def_map.get(r)) |idx| {
                try appendFmt(allocator, buf, "d{d}_{s}", .{ idx, suffix });
            } else {
                try appendFmt(allocator, buf, "r{d}_in", .{r});
            }
        },
        .int => |v| {
            try appendFmt(allocator, buf, "#x{x:0>16}", .{@as(u64, @bitCast(v))});
        },
        .bool => |v| {
            try appendFmt(allocator, buf, "#x{x:0>16}", .{@as(u64, if (v) 1 else 0)});
        },
        .float => |v| {
            try appendFmt(allocator, buf, "#x{x:0>16}", .{@as(u64, @bitCast(v))});
        },
        else => {
            try buf.appendSlice(allocator, "#x0000000000000000");
        },
    }
}

var z3_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

fn runZ3(allocator: std.mem.Allocator, smt_input: []const u8) !bool {
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const id = z3_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.allocPrint(allocator, "z3v_{d}.smt2", .{id});
    defer allocator.free(tmp_path);

    var tmp_file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
    var tmp_buf: [4096]u8 = undefined;
    var tmp_writer = std.Io.File.Writer.init(tmp_file, io, &tmp_buf);
    try tmp_writer.interface.writeAll(smt_input);
    try tmp_writer.flush();
    tmp_file.close(io);

    const result = std.process.run(allocator, io, .{ .argv = &.{ z3_path, tmp_path } }) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    cwd.deleteFile(io, tmp_path) catch {};

    if (result.term != .exited) return error.Z3Failure;
    const trimmed = std.mem.trim(u8, result.stdout, " \n\r");
    if (std.mem.eql(u8, trimmed, "unsat")) return true;
    if (std.mem.eql(u8, trimmed, "sat")) return false;
    return error.Z3Failure;
}
