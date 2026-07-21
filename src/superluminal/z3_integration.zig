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

fn getLastDest(instructions: []const IRInstruction) ?u32 {
    var last: ?u32 = null;
    for (instructions) |instr| {
        if (instr.dest) |d| last = d;
    }
    return last;
}

fn encodeEquivalenceQuery(allocator: std.mem.Allocator, a: []const IRInstruction, b: []const IRInstruction) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

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

    try buf.appendSlice(allocator, "\n; orig\n");
    try encodeSeq(allocator, &buf, a, "_orig");

    try buf.appendSlice(allocator, "\n; trans\n");
    try encodeSeq(allocator, &buf, b, "_trans");

    const last_a = getLastDest(a) orelse return error.NoDestReg;

    try appendFmt(allocator, &buf, "\n(assert (not (= r{d}_orig r{d}_trans)))\n(check-sat)\n", .{ last_a, last_a });

    return buf.toOwnedSlice(allocator);
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

fn encodeSeq(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), instructions: []const IRInstruction, suffix: []const u8) !void {
    for (instructions) |instr| {
        try encInstr(allocator, buf, instr, suffix);
    }
}

fn encInstr(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), instr: IRInstruction, suffix: []const u8) !void {
    const d = instr.dest orelse return;
    const dn = try std.fmt.allocPrint(allocator, "r{d}_{s}", .{ d, suffix });
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
            try encVal(allocator, buf, instr.operand1, suffix);
            try buf.appendSlice(allocator, ")\n");
        },
        .load_var => {
            try appendFmt(allocator, buf, "(define-fun {s} () (_ BitVec 64) {s})\n", .{ dn, instr.operand1.string });
        },
        .add => try encBin(allocator, buf, dn, instr, suffix, "bvadd"),
        .sub => try encBin(allocator, buf, dn, instr, suffix, "bvsub"),
        .mul => try encBin(allocator, buf, dn, instr, suffix, "bvmul"),
        .div => try encBin(allocator, buf, dn, instr, suffix, "bvsdiv"),
        .mod => try encBin(allocator, buf, dn, instr, suffix, "bvsrem"),
        .and_op => try encBin(allocator, buf, dn, instr, suffix, "bvand"),
        .or_op => try encBin(allocator, buf, dn, instr, suffix, "bvor"),
        .eq => try encCmp(allocator, buf, dn, instr, suffix, "="),
        .ne => try encCmp(allocator, buf, dn, instr, suffix, "distinct"),
        .lt => try encCmp(allocator, buf, dn, instr, suffix, "bvslt"),
        .le => try encCmp(allocator, buf, dn, instr, suffix, "bvsle"),
        .gt => try encCmp(allocator, buf, dn, instr, suffix, "bvsgt"),
        .ge => try encCmp(allocator, buf, dn, instr, suffix, "bvsge"),
        .neg => {
            try buf.appendSlice(allocator, "(define-fun ");
            try buf.appendSlice(allocator, dn);
            try buf.appendSlice(allocator, " () (_ BitVec 64) (bvneg ");
            try encVal(allocator, buf, instr.operand1, suffix);
            try buf.appendSlice(allocator, "))\n");
        },
        .not_op => {
            try buf.appendSlice(allocator, "(define-fun ");
            try buf.appendSlice(allocator, dn);
            try buf.appendSlice(allocator, " () (_ BitVec 64) (bvnot ");
            try encVal(allocator, buf, instr.operand1, suffix);
            try buf.appendSlice(allocator, "))\n");
        },
        else => {
            try appendFmt(allocator, buf, "(define-fun {s} () (_ BitVec 64) #x0000000000000000)\n", .{dn});
        },
    }
}

fn encBin(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dn: []const u8, instr: IRInstruction, suffix: []const u8, op: []const u8) !void {
    try buf.appendSlice(allocator, "(define-fun ");
    try buf.appendSlice(allocator, dn);
    try buf.appendSlice(allocator, " () (_ BitVec 64) (");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand1, suffix);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand2, suffix);
    try buf.appendSlice(allocator, "))\n");
}

fn encCmp(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), dn: []const u8, instr: IRInstruction, suffix: []const u8, op: []const u8) !void {
    try buf.appendSlice(allocator, "(define-fun ");
    try buf.appendSlice(allocator, dn);
    try buf.appendSlice(allocator, " () (_ BitVec 64) (ite (");
    try buf.appendSlice(allocator, op);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand1, suffix);
    try buf.appendSlice(allocator, " ");
    try encVal(allocator, buf, instr.operand2, suffix);
    try buf.appendSlice(allocator, ") #x0000000000000001 #x0000000000000000))\n");
}

fn encVal(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: IRValue, suffix: []const u8) !void {
    switch (val) {
        .register => |r| {
            try appendFmt(allocator, buf, "r{d}_{s}", .{ r, suffix });
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

fn runZ3(allocator: std.mem.Allocator, smt_input: []const u8) !bool {
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const tmp_path = "z3v.smt2";
    var tmp_file = try cwd.createFile(io, tmp_path, .{ .truncate = true });
    var tmp_buf: [4096]u8 = undefined;
    var tmp_writer = std.Io.File.Writer.init(tmp_file, io, &tmp_buf);
    try tmp_writer.interface.writeAll(smt_input);
    try tmp_writer.flush();
    tmp_file.close(io);

    const result = std.process.run(allocator, io, .{ .argv = &.{ z3_path, tmp_path } }) catch {
        cwd.deleteFile(io, tmp_path) catch {};
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    cwd.deleteFile(io, tmp_path) catch {};

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r");
    return result.term == .exited and result.term.exited == 0 and std.mem.eql(u8, trimmed, "unsat");
}
