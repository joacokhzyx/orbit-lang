const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;

pub const SynthesisMatch = struct {
    start: usize,
    length: usize,
    rule_index: usize,
};

pub const RuleInfo = struct {
    name: []const u8,
    cost_reduction: f64,
};

pub fn getRuleInfo(index: usize) RuleInfo {
    return RuleInfo{
        .name = rules[index].name,
        .cost_reduction = rules[index].cost_reduction,
    };
}

const Rule = struct {
    name: []const u8,
    matchFn: *const fn (instructions: []const IRInstruction, start: usize) ?usize,
    cost_reduction: f64,
};

const rules = [_]Rule{
    .{ .name = "mul2_shl1", .matchFn = matchMulPow2, .cost_reduction = 2.0 },
    .{ .name = "div2_shr1", .matchFn = matchDivPow2, .cost_reduction = 2.0 },
    .{ .name = "mod_pow2_and", .matchFn = matchModPow2, .cost_reduction = 2.0 },
    .{ .name = "double_neg", .matchFn = matchDoubleNeg, .cost_reduction = 1.0 },
    .{ .name = "not_not", .matchFn = matchNotNot, .cost_reduction = 1.0 },
    .{ .name = "add_zero", .matchFn = matchAddZero, .cost_reduction = 1.0 },
    .{ .name = "mul_one", .matchFn = matchMulOne, .cost_reduction = 1.0 },
    .{ .name = "mul_zero", .matchFn = matchMulZero, .cost_reduction = 1.0 },
    .{ .name = "sub_self", .matchFn = matchSubSelf, .cost_reduction = 1.0 },
    .{ .name = "increment", .matchFn = matchInc, .cost_reduction = 1.5 },
    .{ .name = "decrement", .matchFn = matchDec, .cost_reduction = 1.5 },
    .{ .name = "bool_and_true", .matchFn = matchBoolAndTrue, .cost_reduction = 1.0 },
    .{ .name = "bool_or_false", .matchFn = matchBoolOrFalse, .cost_reduction = 1.0 },
    .{ .name = "copy_self", .matchFn = matchCopySelf, .cost_reduction = 1.0 },
    .{ .name = "or_self", .matchFn = matchOrSelf, .cost_reduction = 1.0 },
    .{ .name = "and_self", .matchFn = matchAndSelf, .cost_reduction = 1.0 },
    .{ .name = "eq_self", .matchFn = matchEqSelf, .cost_reduction = 1.0 },
    .{ .name = "ne_self", .matchFn = matchNeSelf, .cost_reduction = 1.0 },
    .{ .name = "sub_zero", .matchFn = matchSubZero, .cost_reduction = 1.0 },
    .{ .name = "cmp_self", .matchFn = matchCmpSelf, .cost_reduction = 1.0 },
    .{ .name = "or_one", .matchFn = matchOrOne, .cost_reduction = 1.0 },
    .{ .name = "and_zero", .matchFn = matchAndZero, .cost_reduction = 1.0 },
};

pub fn findSynthesis(instructions: []const IRInstruction, start: usize) ?SynthesisMatch {
    if (start >= instructions.len) return null;
    inline for (rules, 0..) |rule, i| {
        if (rule.matchFn(instructions, start)) |len| {
            return SynthesisMatch{ .start = start, .length = len, .rule_index = i };
        }
    }
    return null;
}

fn isSameReg(a: IRValue, b: IRValue) bool {
    return a == .register and b == .register and a.register == b.register;
}

fn getConst(instructions: []const IRInstruction, start: usize, reg: u32) ?i64 {
    if (start == 0) return null;
    var i: usize = start;
    while (i > 0) {
        i -= 1;
        const instr = instructions[i];
        if (instr.opcode == .load_const) {
            if (instr.dest) |d| {
                if (d == reg and instr.operand1 == .int) return instr.operand1.int;
            }
        }
    }
    return null;
}

fn isIntConst(val: IRValue, c: i64) bool {
    return val == .int and val.int == c;
}

fn isPow2(n: i64) bool {
    if (n <= 0) return false;
    return (n & (n - 1)) == 0;
}

fn matchMulPow2(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .mul) return null;
    if (i.operand1 == .int and isPow2(i.operand1.int)) return 1;
    if (i.operand1 == .register) {
        if (getConst(instructions, start, i.operand1.register)) |v| {
            if (isPow2(v)) return 1;
        }
    }
    if (i.operand2 == .int and isPow2(i.operand2.int)) return 1;
    if (i.operand2 == .register) {
        if (getConst(instructions, start, i.operand2.register)) |v| {
            if (isPow2(v)) return 1;
        }
    }
    return null;
}

fn matchDivPow2(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .div) return null;
    if (i.operand2 == .int and isPow2(i.operand2.int)) return 1;
    if (i.operand2 == .register) {
        if (getConst(instructions, start, i.operand2.register)) |v| {
            if (isPow2(v)) return 1;
        }
    }
    return null;
}

fn matchModPow2(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .mod) return null;
    if (i.operand2 == .int and isPow2(i.operand2.int)) return 1;
    if (i.operand2 == .register) {
        if (getConst(instructions, start, i.operand2.register)) |v| {
            if (isPow2(v)) return 1;
        }
    }
    return null;
}

fn matchDoubleNeg(instructions: []const IRInstruction, start: usize) ?usize {
    if (start + 1 >= instructions.len) return null;
    const ir0 = instructions[start];
    const ir1 = instructions[start + 1];
    if (ir0.opcode != .neg or ir1.opcode != .neg) return null;
    if (ir0.dest) |d| if (isSameReg(IRValue{ .register = d }, ir1.operand1)) return 2;
    return null;
}

fn matchNotNot(instructions: []const IRInstruction, start: usize) ?usize {
    if (start + 1 >= instructions.len) return null;
    const ir0 = instructions[start];
    const ir1 = instructions[start + 1];
    if (ir0.opcode != .not_op or ir1.opcode != .not_op) return null;
    if (ir0.dest) |d| if (isSameReg(IRValue{ .register = d }, ir1.operand1)) return 2;
    return null;
}

fn matchAddZero(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .add) return null;
    if (isIntConst(i.operand1, 0) or isIntConst(i.operand2, 0)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 0) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 0) return 1;
    return null;
}

fn matchMulOne(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .mul) return null;
    if (isIntConst(i.operand1, 1) or isIntConst(i.operand2, 1)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 1) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 1) return 1;
    return null;
}

fn matchMulZero(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .mul) return null;
    if (isIntConst(i.operand1, 0) or isIntConst(i.operand2, 0)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 0) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 0) return 1;
    return null;
}

fn matchSubSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .sub) return null;
    if (isSameReg(i.operand1, i.operand2)) return 1;
    return null;
}

fn matchInc(instructions: []const IRInstruction, start: usize) ?usize {
    if (start + 1 >= instructions.len) return null;
    const ir0 = instructions[start];
    const ir1 = instructions[start + 1];
    if (ir0.opcode != .add or ir1.opcode != .store_var) return null;
    if (isIntConst(ir0.operand2, 1) or isIntConst(ir0.operand1, 1)) {} else {
        const is_reg1 = ir0.operand1 == .register and (getConst(instructions, start, ir0.operand1.register) orelse 0) == 1;
        const is_reg2 = ir0.operand2 == .register and (getConst(instructions, start, ir0.operand2.register) orelse 0) == 1;
        if (!is_reg1 and !is_reg2) return null;
    }
    if (ir1.operand2 == .register and ir0.dest == ir1.operand2.register) return 2;
    return null;
}

fn matchDec(instructions: []const IRInstruction, start: usize) ?usize {
    if (start + 1 >= instructions.len) return null;
    const ir0 = instructions[start];
    const ir1 = instructions[start + 1];
    if (ir0.opcode != .sub or ir1.opcode != .store_var) return null;
    if (isIntConst(ir0.operand2, 1) or isIntConst(ir0.operand1, 1)) {} else {
        const is_reg1 = ir0.operand1 == .register and (getConst(instructions, start, ir0.operand1.register) orelse 0) == 1;
        const is_reg2 = ir0.operand2 == .register and (getConst(instructions, start, ir0.operand2.register) orelse 0) == 1;
        if (!is_reg1 and !is_reg2) return null;
    }
    if (ir1.operand2 == .register and ir0.dest == ir1.operand2.register) return 2;
    return null;
}

fn matchBoolAndTrue(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .and_op) return null;
    if (isIntConst(i.operand1, 1) or isIntConst(i.operand2, 1)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 1) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 1) return 1;
    return null;
}

fn matchBoolOrFalse(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .or_op) return null;
    if (isIntConst(i.operand1, 0) or isIntConst(i.operand2, 0)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 0) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 0) return 1;
    return null;
}

fn matchCopySelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .copy) return null;
    if (i.dest) |d| if (isSameReg(IRValue{ .register = d }, i.operand1)) return 1;
    return null;
}

fn matchOrSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .or_op) return null;
    if (isSameReg(i.operand1, i.operand2)) return 1;
    return null;
}

fn matchAndSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .and_op) return null;
    if (isSameReg(i.operand1, i.operand2)) return 1;
    return null;
}

fn matchEqSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .eq) return null;
    if (isSameReg(i.operand1, i.operand2)) return 1;
    return null;
}

fn matchNeSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .ne) return null;
    if (isSameReg(i.operand1, i.operand2)) return 1;
    return null;
}

fn matchSubZero(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .sub) return null;
    if (isIntConst(i.operand2, 0)) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 0) return 1;
    return null;
}

fn matchCmpSelf(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (!isSameReg(i.operand1, i.operand2)) return null;
    switch (i.opcode) {
        .lt, .gt => return 1,
        else => return null,
    }
    return null;
}

fn matchOrOne(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .or_op) return null;
    if (isIntConst(i.operand1, 1) or isIntConst(i.operand2, 1)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 1) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 1) return 1;
    return null;
}

fn matchAndZero(instructions: []const IRInstruction, start: usize) ?usize {
    if (start >= instructions.len) return null;
    const i = instructions[start];
    if (i.opcode != .and_op) return null;
    if (isIntConst(i.operand1, 0) or isIntConst(i.operand2, 0)) return 1;
    if (i.operand1 == .register) if (getConst(instructions, start, i.operand1.register)) |v| if (v == 0) return 1;
    if (i.operand2 == .register) if (getConst(instructions, start, i.operand2.register)) |v| if (v == 0) return 1;
    return null;
}
