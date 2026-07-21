const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRFunction = ir.IRFunction;
const IRInstruction = ir.IRInstruction;
const IRType = ir.IRType;
const IRValue = ir.IRValue;

const CBackend = @import("../codegen/c_backend.zig").CBackend;

pub fn emitAssumeNonNull(backend: *CBackend, val: IRValue, obj_type: IRType) !void {
    if (obj_type == .model or obj_type == .tagged_union or obj_type == .pointer or obj_type == .mut_pointer) {
        try backend.output.appendSlice(backend.allocator, "    __builtin_assume(");
        try backend.generateValue(val);
        try backend.output.appendSlice(backend.allocator, " != (void*)0);\n");
    }
}

pub fn emitAssumeRange(backend: *CBackend, val: IRValue, lo: i64, hi: i64) !void {
    try backend.output.appendSlice(backend.allocator, "    __builtin_assume(");
    try backend.generateValue(val);
    try backend.output.print(backend.allocator, " >= {d} && ", .{lo});
    try backend.generateValue(val);
    try backend.output.print(backend.allocator, " <= {d});\n", .{hi});
}

pub fn emitAssumePtrNotAlias(backend: *CBackend, a: IRValue, b: IRValue) !void {
    try backend.output.appendSlice(backend.allocator, "    __builtin_assume(");
    try backend.generateValue(a);
    try backend.output.appendSlice(backend.allocator, " != ");
    try backend.generateValue(b);
    try backend.output.appendSlice(backend.allocator, ");\n");
}

pub fn emitLikelyJump(backend: *CBackend, cond: IRValue, target: IRValue) !void {
    try backend.output.appendSlice(backend.allocator, "if (__builtin_expect(");
    try backend.generateValue(cond);
    try backend.output.appendSlice(backend.allocator, ", 0)) goto ");
    try backend.generateValue(target);
    try backend.output.appendSlice(backend.allocator, ";\n");
}

pub fn emitRestrictParam(backend: *CBackend, param_name: []const u8, param_type: IRType) ![]const u8 {
    if (param_type == .model or param_type == .tagged_union or param_type == .pointer or param_type == .mut_pointer) {
        return try std.fmt.allocPrint(backend.allocator, "__restrict {s}", .{param_name});
    }
    return param_name;
}

pub fn emitAlwaysInline(backend: *CBackend, func: IRFunction) !void {
    if (func.instructions.items.len <= 10) {
        try backend.output.appendSlice(backend.allocator, "__attribute__((always_inline)) ");
    }
}

pub fn shouldAnnotateFunction(func: IRFunction) bool {
    return func.instructions.items.len <= 10 and func.instructions.items.len > 0;
}
