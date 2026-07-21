const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;

var z3_available: ?bool = null;
var z3_path: ?[]const u8 = null;

pub fn isAvailable() bool {
    if (z3_available) |avail| return avail;
    z3_available = findZ3();
    return z3_available.?;
}

fn findZ3() bool {
    const search_dirs = [_][]const u8{ "C:\\Program Files\\Z3\\z3.exe", "/usr/bin/z3", "/usr/local/bin/z3" };
    for (search_dirs) |path| {
        if (std.fs.accessAbsolute(path, .{})) {
            z3_path = path;
            return true;
        } else |_| {}
    }
    return false;
}

pub fn verifyEquivalence(allocator: std.mem.Allocator, original: []const IRInstruction, transformed: []const IRInstruction) !bool {
    if (!isAvailable()) return false;

    const smt = try encodeEquivalence(allocator, original, transformed);
    defer allocator.free(smt);

    return try queryZ3(allocator, smt);
}

fn encodeEquivalence(allocator: std.mem.Allocator, original: []const IRInstruction, transformed: []const IRInstruction) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const w = buf.writer();

    try w.writeAll("(set-logic QF_AUFBV)\n");
    try w.writeAll("(set-option :produce-models false)\n\n");

    try w.writeAll("; Declare symbolic variables\n");
    for (original) |instr| {
        switch (instr.opcode) {
            .load_var => {
                try w.print("(declare-fun {s} () (_ BitVec 64))\n", .{instr.operand1.string});
            },
            else => {},
        }
    }

    try w.writeAll("\n; Encode original sequence\n");
    try encodeSequence(w, original);

    try w.writeAll("\n; Encode transformed sequence\n");
    try encodeSequence(w, transformed);

    const last_orig = if (original.len > 0) original[original.len - 1].dest else return true;
    const last_trans = if (transformed.len > 0) transformed[transformed.len - 1].dest else return true;

    try w.print("\n(assert (not (= r{1}_orig r{1}_trans)))\n", .{last_orig});
    _ = last_trans;
    try w.print("(check-sat)\n", .{});

    return buf.toOwnedSlice();
}

fn encodeSequence(w: anytype, instructions: []const IRInstruction) !void {
    _ = w;
    _ = instructions;
}

fn queryZ3(allocator: std.mem.Allocator, smt: []const u8) !bool {
    _ = allocator;
    _ = smt;
    return false;
}
