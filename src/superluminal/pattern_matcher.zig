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
        tryArgInline(instructions, start),
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
    if (store_field.operand2 != .string and store_field.operand2 != .symbol) return null;
    const store_field_name = switch (store_field.operand2) {
        .string => |s| s,
        .symbol => |s| s,
        else => return null,
    };
    const store_src = store_field.operand3;

    if (store_src != .register) return null;
    if (store_src.register != binop.dest.?) return null;

    const load_obj = load_field.operand1;
    if (load_field.operand2 != .string and load_field.operand2 != .symbol) return null;
    const load_field_name = switch (load_field.operand2) {
        .string => |s| s,
        .symbol => |s| s,
        else => return null,
    };

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
    // Pattern: result_is_ok rA -> rB; jump_if_false rB label_err;
    //          begin_block; result_unwrap rA -> rC; end_block;
    //          jump label_end; label_err:; begin_block; <simple_val> -> rC; end_block; label_end:
    if (start + 11 >= instructions.len) return null;

    const is_ok = instructions[start];
    if (is_ok.opcode != .result_is_ok) return null;
    const result_reg = is_ok.operand1;
    const ok_reg = is_ok.dest orelse return null;

    const jmp_if = instructions[start + 1];
    if (jmp_if.opcode != .jump_if_false) return null;
    if (jmp_if.operand1 != .register or jmp_if.operand1.register != ok_reg) return null;
    const err_label = if (jmp_if.operand2 == .label) jmp_if.operand2.label else return null;

    const bb1 = instructions[start + 2];
    if (bb1.opcode != .begin_block) return null;

    const unwrap = instructions[start + 3];
    if (unwrap.opcode != .result_unwrap) return null;
    if (!std.meta.eql(unwrap.operand1, result_reg)) return null;
    _ = unwrap.dest orelse return null;

    const eb1 = instructions[start + 4];
    if (eb1.opcode != .end_block) return null;

    const jump_end_instr = instructions[start + 5];
    if (jump_end_instr.opcode != .jump) return null;
    const end_label = if (jump_end_instr.operand1 == .label) jump_end_instr.operand1.label else return null;

    const label_err_instr = instructions[start + 6];
    if (label_err_instr.opcode != .label) return null;
    if (label_err_instr.operand1 != .label or label_err_instr.operand1.label != err_label) return null;

    const bb2 = instructions[start + 7];
    if (bb2.opcode != .begin_block) return null;

    const fallback = instructions[start + 8];
    const fallback_reg = fallback.dest orelse return null;

    const eb2 = instructions[start + 9];
    if (eb2.opcode != .end_block) return null;

    const label_end_instr = instructions[start + 10];
    if (label_end_instr.opcode != .label) return null;
    if (label_end_instr.operand1 != .label or label_end_instr.operand1.label != end_label) return null;

    if (fallback.opcode != .copy and fallback.opcode != .load_var and fallback.opcode != .load_const) return null;
    _ = fallback_reg;

    const before = cost_model.evaluateSlice(instructions[start .. start + 11]);
    const after = Cost{
        .mem_read = 2,
        .alu = 1,
    };

    return Match{
        .kind = .ternary_rescue,
        .start = start,
        .length = 11,
        .cost_before = before,
        .cost_after = after,
    };
}

fn tryChainedField(instructions: []const IRInstruction, start: usize) ?Match {
    if (start + 1 >= instructions.len) return null;

    const first = instructions[start];
    const second = instructions[start + 1];

    if (first.opcode != .load_field) return null;
    if (second.opcode != .load_field) return null;
    if (first.operand2 != .string and first.operand2 != .symbol) return null;
    if (second.operand2 != .string and second.operand2 != .symbol) return null;

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

fn tryArgInline(instructions: []const IRInstruction, start: usize) ?Match {
    if (start >= instructions.len) return null;
    if (instructions[start].opcode != .arg) return null;

    // Count consecutive arg instructions
    var arg_count: usize = 0;
    var pos = start;
    while (pos < instructions.len and instructions[pos].opcode == .arg) {
        arg_count += 1;
        pos += 1;
    }

    if (arg_count == 0) return null;
    if (pos >= instructions.len or instructions[pos].opcode != .call) return null;
    const call_instr = instructions[pos];
    if (call_instr.operand1 != .string and call_instr.operand1 != .symbol) return null;

    const total_len = arg_count + 1;

    const before = cost_model.evaluateSlice(instructions[start .. start + total_len]);
    const after = Cost{
        .mem_read = 0,
        .alu = 0,
        .branch = 0,
        .reg_assign = 0,
        .call = 1,
    };

    return Match{
        .kind = .arg_inline,
        .start = start,
        .length = total_len,
        .cost_before = before,
        .cost_after = after,
    };
}

fn tryMatchSwitch(instructions: []const IRInstruction, start: usize) ?Match {
    // Pattern: union_get_tag r_obj -> r_tag;
    //          { eq r_tag TAG_N -> r_cmpN; jump_if_false r_cmpN label_N;
    //            begin_block; union_get_data r_obj TAG_N -> r_dataN;
    //            (optional: decl_var name r_dataN); <body...>; end_block; jump label_end;
    //            label_N:; } * N
    //          label_end:
    if (start + 3 >= instructions.len) return null;

    const get_tag = instructions[start];
    if (get_tag.opcode != .union_get_tag) return null;
    const tag_reg = get_tag.dest orelse return null;
    const obj_val = get_tag.operand1;

    var case_count: usize = 0;
    var pos = start + 1;
    var found_end_label: ?u32 = null;
    var total_instructions: usize = 1;

    while (pos < instructions.len) {
        const eq = instructions[pos];
        if (eq.opcode != .eq) break;
        if (eq.operand1 != .register or eq.operand1.register != tag_reg) break;
        const tag_symbol = if (eq.operand2 == .symbol) eq.operand2.symbol else break;
        // Verify tag name follows convention *_TAG_*
        var found_tag: bool = false;
        for (tag_symbol, 0..) |c, i| {
            if (i + 4 < tag_symbol.len and c == '_' and tag_symbol[i + 1] == 'T' and tag_symbol[i + 2] == 'A' and tag_symbol[i + 3] == 'G' and tag_symbol[i + 4] == '_') {
                found_tag = true;
                break;
            }
        }
        if (!found_tag) break;
        _ = eq.dest orelse break;

        const jf = instructions[pos + 1];
        if (jf.opcode != .jump_if_false) break;

        const bb = instructions[pos + 2];
        if (bb.opcode != .begin_block) break;

        // Check for optional union_get_data + decl_var
        var body_start = pos + 3;
        const maybe_get_data = instructions[body_start];
        if (maybe_get_data.opcode == .union_get_data) {
            if (std.meta.eql(maybe_get_data.operand1, obj_val)) {
                body_start += 1;
                const maybe_decl = instructions[body_start];
                if (maybe_decl.opcode == .decl_var) {
                    body_start += 1;
                }
            }
        }

        // Find end_block closing this case
        var case_body_len: usize = 0;
        var depth: usize = 1;
        var scan = body_start;
        while (scan < instructions.len and depth > 0) {
            if (instructions[scan].opcode == .begin_block) depth += 1;
            if (instructions[scan].opcode == .end_block) depth -= 1;
            case_body_len += 1;
            scan += 1;
        }
        if (depth != 0) break;

        const jmp = instructions[body_start + case_body_len - 2]; // jump before end_block
        if (jmp.opcode != .jump) break;
        if (jmp.operand1 == .label) {
            found_end_label = jmp.operand1.label;
        }

        const case_label = instructions[pos + 1].operand2; // target of jump_if_false
        _ = case_label;

        pos = body_start + case_body_len;
        case_count += 1;

        // Check for label at this position (next case or end)
        if (pos >= instructions.len) break;
        const next_label = instructions[pos];
        if (next_label.opcode == .label) {
            if (found_end_label) |el| {
                if (next_label.operand1 == .label and next_label.operand1.label == el) {
                    pos += 1;
                    break;
                }
            }
            pos += 1;
        } else {
            break;
        }
    }

    if (case_count < 2) return null;

    total_instructions = pos - start;
    const before = cost_model.evaluateSlice(instructions[start..pos]);

    // After optimization: switch overhead + 1 branch per case (implicit in switch)
    const after = Cost{
        .mem_read = 1,
        .alu = 1,
        .branch = @as(u32, @intCast(case_count)),
    };

    return Match{
        .kind = .match_switch,
        .start = start,
        .length = total_instructions,
        .cost_before = before,
        .cost_after = after,
    };
}
