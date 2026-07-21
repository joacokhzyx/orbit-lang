const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const match = @import("pattern_matcher.zig");
const PatternKind = match.PatternKind;

const CBackend = @import("../codegen/c_backend.zig").CBackend;

pub fn emitPattern(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    switch (m.kind) {
        .compound_assign => try emitCompoundAssign(backend, instructions, m),
        .ternary_rescue => try emitTernaryRescue(backend, instructions, m),
        .chained_field => try emitChainedField(backend, instructions, m),
        .return_local => try emitReturnLocal(backend, instructions, m),
        .arg_inline => try emitArgInline(backend, instructions, m),
        .match_switch => try emitMatchSwitch(backend, instructions, m),
    }
}

fn emitCompoundAssign(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const load_field = instructions[0];
    const binop = instructions[1];
    const rhs = instructions[2];
    const store_field = instructions[3];
    _ = store_field;

    try backend.output.appendSlice(backend.allocator, "    ");
    try backend.generateValue(load_field.operand1);
    const obj_type = backend.getValueType(load_field.operand1);
    if (obj_type == .model or obj_type == .unknown or obj_type == .int) {
        try backend.output.append(backend.allocator, '-');
        try backend.output.append(backend.allocator, '>');
    } else {
        try backend.output.append(backend.allocator, '.');
    }
    try backend.output.appendSlice(backend.allocator, load_field.operand2.string);

    const assign_op = switch (binop.opcode) {
        .add => " += ",
        .sub => " -= ",
        .mul => " *= ",
        .div => " /= ",
        .mod => " %= ",
        else => " = ",
    };
    try backend.output.appendSlice(backend.allocator, assign_op);

    switch (rhs.opcode) {
        .load_const => try backend.generateValue(rhs.operand1),
        .load_var => try backend.output.appendSlice(backend.allocator, rhs.operand1.string),
        .copy => try backend.generateValue(rhs.operand1),
        else => try backend.generateValue(binop.operand2),
    }
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitTernaryRescue(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = backend;
    _ = instructions;
    _ = m;
}

fn emitChainedField(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const first = instructions[0];
    const second = instructions[1];

    try backend.output.print(backend.allocator, "    r_{d} = ", .{second.dest.?});
    try backend.generateValue(first.operand1);
    try backend.output.append(backend.allocator, '-');
    try backend.output.append(backend.allocator, '>');
    try backend.output.appendSlice(backend.allocator, first.operand2.string);
    try backend.output.append(backend.allocator, '-');
    try backend.output.append(backend.allocator, '>');
    try backend.output.appendSlice(backend.allocator, second.operand2.string);
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitReturnLocal(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const load_var = instructions[0];

    try backend.output.appendSlice(backend.allocator, "    return ");
    try backend.output.appendSlice(backend.allocator, load_var.operand1.string);
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitArgInline(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = backend;
    _ = instructions;
    _ = m;
}

fn emitMatchSwitch(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = backend;
    _ = instructions;
    _ = m;
}
