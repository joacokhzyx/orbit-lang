const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;
const cost_model = @import("cost_model.zig");
const Cost = cost_model.Cost;

pub const PatternKind = enum {
    compound_assign,
    ternary_rescue,
    chained_field,
    return_local,
    arg_inline,
    match_switch,
};

pub const Match = struct {
    kind: PatternKind,
    start: usize,
    length: usize,
    cost_before: Cost,
    cost_after: Cost,

    pub fn speedup(self: Match) f64 {
        return cost_model.speedupFactor(self.cost_before, self.cost_after);
    }
};

pub const MIN_SPEEDUP = 1.2;

pub fn findBest(instructions: []const IRInstruction, start: usize) ?Match {
    const candidates = [_]?Match{
        tryMatchSwitch(instructions, start),
        tryCompoundAssign(instructions, start),
        tryTernaryRescue(instructions, start),
        tryChainedField(instructions, start),
        tryReturnLocal(instructions, start),
    };

    var best: ?Match = null;
    for (candidates) |candidate| {
        const m = candidate orelse continue;
        if (m.speedup() < MIN_SPEEDUP) continue;
        if (best) |b| {
            if (m.speedup() > b.speedup()) {
                best = candidate;
            }
        } else {
            best = candidate;
        }
    }
    return best;
}

fn opIsBinaryArithmetic(op: IROpcode) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

fn opToCAssignOp(op: IROpcode) ?[]const u8 {
    return switch (op) {
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
        .mod => "%=",
        else => null,
    };
}

fn tryCompoundAssign(instructions: []const IRInstruction, start: usize) ?Match {
    if (start + 3 >= instructions.len) return null;

    const load_field = instructions[start];
    if (load_field.opcode != .load_field) return null;
    _ = load_field.dest orelse return null;

    const binop = instructions[start + 1];
    _ = opToCAssignOp(binop.opcode) orelse return null;
    if (binop.dest == null) return null;

    _ = instructions[start + 2];

    const store_field = instructions[start + 3];
    if (store_field.opcode != .store_field) return null;

    const store_obj = store_field.operand1;
    const store_field_name = store_field.operand2.string;
    const store_src = store_field.operand3;

    if (store_src != .register) return null;
    if (store_src.register != binop.dest.?) return null;

    const load_obj = load_field.operand1;
    const load_field_name = load_field.operand2.string;

    if (!std.meta.eql(load_obj, store_obj)) return null;
    if (!std.mem.eql(u8, load_field_name, store_field_name)) return null;

    const before = cost_model.evaluateSlice(instructions[start .. start + 4]);
    const after = Cost{
        .alu = if (binop.opcode == .add or binop.opcode == .sub) 1 else 1,
        .mem_read = 1,
        .mem_write = 1,
    };

    return Match{
        .kind = .compound_assign,
        .start = start,
        .length = 4,
        .cost_before = before,
        .cost_after = after,
    };
}

fn tryTernaryRescue(instructions: []const IRInstruction, start: usize) ?Match {
    _ = instructions;
    _ = start;
    return null;
}

fn tryChainedField(instructions: []const IRInstruction, start: usize) ?Match {
    if (start + 1 >= instructions.len) return null;

    const first = instructions[start];
    const second = instructions[start + 1];

    if (first.opcode != .load_field) return null;
    if (second.opcode != .load_field) return null;

    const first_dest = first.dest orelse return null;
    const second_src = second.operand1;
    if (second_src != .register) return null;
    if (second_src.register != first_dest) return null;

    const before = cost_model.evaluateSlice(instructions[start .. start + 2]);
    const after = Cost{
        .mem_read = 3,
        .reg_assign = 1,
    };

    return Match{
        .kind = .chained_field,
        .start = start,
        .length = 2,
        .cost_before = before,
        .cost_after = after,
    };
}

fn tryReturnLocal(instructions: []const IRInstruction, start: usize) ?Match {
    if (start + 1 >= instructions.len) return null;

    const load_var = instructions[start];
    const ret = instructions[start + 1];

    if (load_var.opcode != .load_var) return null;
    if (ret.opcode != .ret) return null;

    const load_dest = load_var.dest orelse return null;
    if (ret.operand1 != .register) return null;
    if (ret.operand1.register != load_dest) return null;

    const before = cost_model.evaluateSlice(instructions[start .. start + 2]);
    const after = Cost{
        .mem_read = 1,
    };

    return Match{
        .kind = .return_local,
        .start = start,
        .length = 2,
        .cost_before = before,
        .cost_after = after,
    };
}

fn tryMatchSwitch(instructions: []const IRInstruction, start: usize) ?Match {
    _ = instructions;
    _ = start;
    return null;
}
