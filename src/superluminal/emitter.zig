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

fn getValString(val: IRValue) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        .symbol => |s| s,
        else => null,
    };
}

fn emitCompoundAssign(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const load_field = instructions[0];
    const binop = instructions[1];
    const rhs = instructions[2];
    const store_field = instructions[3];
    _ = store_field;

    const f_str = getValString(load_field.operand2) orelse return error.InvalidPattern;

    try backend.output.appendSlice(backend.allocator, "    ");
    try backend.generateValue(load_field.operand1);
    const obj_type = backend.getValueType(load_field.operand1);
    if (obj_type == .model or obj_type == .unknown or obj_type == .int) {
        try backend.output.append(backend.allocator, '-');
        try backend.output.append(backend.allocator, '>');
    } else {
        try backend.output.append(backend.allocator, '.');
    }
    try backend.output.appendSlice(backend.allocator, f_str);

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
        .load_var => if (getValString(rhs.operand1)) |s| try backend.output.appendSlice(backend.allocator, s) else return error.InvalidPattern,
        .copy => try backend.generateValue(rhs.operand1),
        else => try backend.generateValue(binop.operand2),
    }
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitTernaryRescue(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const is_ok = instructions[0];
    const unwrap = instructions[3];
    const fallback = instructions[8];
    const val_reg = unwrap.dest.?;
    const result_val = is_ok.operand1;

    try backend.output.print(backend.allocator, "    r_{d} = ", .{val_reg});
    try backend.generateValue(result_val);
    try backend.output.appendSlice(backend.allocator, ".ok ? ");
    try backend.generateValue(result_val);
    try backend.output.appendSlice(backend.allocator, ".value : ");

    switch (fallback.opcode) {
        .copy => try backend.generateValue(fallback.operand1),
        .load_var => if (getValString(fallback.operand1)) |s| try backend.output.appendSlice(backend.allocator, s) else return error.InvalidPattern,
        .load_const => try backend.generateValue(fallback.operand1),
        else => {},
    }
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitChainedField(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const first = instructions[0];
    const second = instructions[1];

    const f1_str = getValString(first.operand2) orelse return error.InvalidPattern;
    const f2_str = getValString(second.operand2) orelse return error.InvalidPattern;

    try backend.output.print(backend.allocator, "    r_{d} = ", .{second.dest.?});
    try backend.generateValue(first.operand1);
    try backend.output.appendSlice(backend.allocator, "->");
    try backend.output.appendSlice(backend.allocator, f1_str);
    try backend.output.appendSlice(backend.allocator, "->");
    try backend.output.appendSlice(backend.allocator, f2_str);
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitReturnLocal(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const load_var = instructions[0];
    const var_str = getValString(load_var.operand1) orelse return error.InvalidPattern;

    try backend.output.appendSlice(backend.allocator, "    return ");
    try backend.output.appendSlice(backend.allocator, var_str);
    try backend.output.appendSlice(backend.allocator, ";\n");
}

fn emitArgInline(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    const len = m.length;
    if (len == 0 or len > instructions.len) return error.InvalidPattern;
    const call_instr = instructions[len - 1];
    const func_name = getValString(call_instr.operand1) orelse return error.InvalidPattern;

    if (call_instr.dest) |d| {
        const reg_type = if (backend.current_func) |f| f.register_types.items[d] else .unknown;
        const callee_ret = backend.function_return_types.get(func_name) orelse .unknown;
        if (reg_type != .void and callee_ret != .void) {
            try backend.output.print(backend.allocator, "    r_{d} = ", .{d});
        }
    } else {
        try backend.output.appendSlice(backend.allocator, "    ");
    }

    const func_name_buf = try backend.allocator.dupe(u8, func_name);
    defer backend.allocator.free(func_name_buf);
    for (func_name_buf) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) c.* = '_';
    }
    try backend.output.appendSlice(backend.allocator, func_name_buf);
    try backend.output.append(backend.allocator, '(');

    var first = true;

    // First, drain any existing call_args from prior singleton arg emissions
    for (backend.call_args.items) |arg| {
        if (!first) try backend.output.appendSlice(backend.allocator, ", ");
        try backend.generateValue(arg);
        first = false;
    }
    backend.call_args.clearRetainingCapacity();

    // Now emit the pattern's arg values inline
    var i: usize = 0;
    while (i < len - 1) : (i += 1) {
        if (instructions[i].opcode != .arg) continue;
        if (!first) try backend.output.appendSlice(backend.allocator, ", ");
        try backend.generateValue(instructions[i].operand1);
        first = false;
    }

    try backend.output.appendSlice(backend.allocator, ");\n");
}

fn emitMatchSwitch(backend: *CBackend, instructions: []const IRInstruction, m: match.Match) !void {
    _ = m;
    const get_tag = instructions[0];
    const obj_val = get_tag.operand1;

    try backend.output.appendSlice(backend.allocator, "    switch (");
    try backend.generateValue(obj_val);
    try backend.output.appendSlice(backend.allocator, "->tag) {\n");

    var pos: usize = 1;
    while (pos < instructions.len) {
        const eq = instructions[pos];
        if (eq.opcode != .eq) break;
        const tag_symbol = eq.operand2.symbol;

        const bb = instructions[pos + 2];
        _ = bb;

        var body_start = pos + 3;
        const maybe_get_data = instructions[body_start];
        if (maybe_get_data.opcode == .union_get_data and std.meta.eql(maybe_get_data.operand1, obj_val)) {
            body_start += 1;
            const maybe_decl = instructions[body_start];
            if (maybe_decl.opcode == .decl_var) {
                body_start += 1;
            }
        }

        try backend.output.print(backend.allocator, "        case {s}: {{\n", .{tag_symbol});

        var depth: usize = 1;
        var scan = body_start;
        while (scan < instructions.len and depth > 0) {
            const instr = instructions[scan];
            if (instr.opcode == .begin_block) depth += 1;
            if (instr.opcode == .end_block) depth -= 1;
            if (depth > 0) {
                try backend.generateInstruction(instr);
            }
            scan += 1;
        }

        try backend.output.appendSlice(backend.allocator, "            break;\n");
        try backend.output.appendSlice(backend.allocator, "        }}\n");

        pos = scan;
        if (pos < instructions.len and instructions[pos].opcode == .label) {
            const is_end_label = instructions[pos].operand1 == .label and
                (instructions.len > 5 and instructions[5].operand1 == .label and instructions[pos].operand1.label == instructions[5].operand1.label);
            if (is_end_label) break;
            pos += 1;
        }
    }

    try backend.output.appendSlice(backend.allocator, "        default: break;\n");
    try backend.output.appendSlice(backend.allocator, "    }\n");
}
