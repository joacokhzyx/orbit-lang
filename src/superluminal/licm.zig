const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass = @import("pass_runner.zig");

pub const LoopInfo = struct {
    header_idx: usize,
    back_edge_idx: usize,
};

fn findNaturalLoops(instructions: []const IRInstruction, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(LoopInfo) {
    var loops = std.ArrayListUnmanaged(LoopInfo).empty;

    for (instructions, 0..) |instr, i| {
        if (instr.opcode == .jump or instr.opcode == .jump_if_false) {
            const target = pass.getJumpTarget(instr);
            if (target) |t| {
                if (pass.findLabel(instructions, t)) |label_pos| {
                    if (label_pos < i) {
                        try loops.append(allocator, LoopInfo{
                            .header_idx = label_pos,
                            .back_edge_idx = i,
                        });
                    }
                }
            }
        }
    }

    std.mem.sort(LoopInfo, loops.items, {}, struct {
        fn less(_: void, a: LoopInfo, b: LoopInfo) bool {
            if (a.header_idx != b.header_idx) return a.header_idx < b.header_idx;
            return a.back_edge_idx < b.back_edge_idx;
        }
    }.less);

    return loops;
}

fn isDefinedInBody(body: []const IRInstruction, reg: u32) bool {
    for (body) |instr| {
        if (instr.dest) |d| if (d == reg) return true;
    }
    return false;
}

fn isSupportedInvariant(instr: IRInstruction) bool {
    return switch (instr.opcode) {
        .load_const, .add, .sub, .mul, .neg, .not_op, .and_op, .or_op, .eq, .ne, .lt, .le, .gt, .ge, .copy => true,
        else => false,
    };
}

pub fn loopInvariantCodeMotion(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var loops = try findNaturalLoops(instructions, allocator);
    defer loops.deinit(allocator);

    if (loops.items.len == 0) return null;

    var result_slice = try allocator.dupe(IRInstruction, instructions);
    var modified = false;

    for (loops.items) |loop| {
        const header = loop.header_idx;
        const back = loop.back_edge_idx;
        const body = result_slice[header + 1 .. back];

        if (body.len == 0) continue;

        var invariant_indices = std.ArrayListUnmanaged(usize).empty;
        defer invariant_indices.deinit(allocator);

        var changed = true;
        while (changed) {
            changed = false;
            for (body, 0..) |instr, idx| {
                if (!isSupportedInvariant(instr)) continue;

                var already = false;
                for (invariant_indices.items) |iv| if (iv == idx) {
                    already = true;
                    break;
                };
                if (already) continue;

                const regs = [_]?u32{
                    if (instr.operand1 == .register) instr.operand1.register else null,
                    if (instr.operand2 == .register) instr.operand2.register else null,
                    if (instr.operand3 == .register) instr.operand3.register else null,
                };

                var all_invariant = true;
                for (regs) |reg_opt| {
                    const reg = reg_opt orelse continue;
                    if (isDefinedInBody(body, reg)) {
                        var defined_by_invariant = false;
                        for (invariant_indices.items) |iv_idx| {
                            if (body[iv_idx].dest) |d| {
                                if (d == reg) {
                                    defined_by_invariant = true;
                                    break;
                                }
                            }
                        }
                        if (!defined_by_invariant) {
                            all_invariant = false;
                            break;
                        }
                    }
                }

                if (all_invariant) {
                    try invariant_indices.append(allocator, idx);
                    changed = true;
                }
            }
        }

        if (invariant_indices.items.len > 0) {
            var new_instructions = std.ArrayListUnmanaged(IRInstruction).empty;
            errdefer new_instructions.deinit(allocator);

            for (result_slice[0 .. header + 1]) |instr| try new_instructions.append(allocator, instr);

            for (invariant_indices.items) |iv_idx| try new_instructions.append(allocator, body[iv_idx]);

            var skip_set = std.AutoHashMap(usize, void).init(allocator);
            defer skip_set.deinit();
            for (invariant_indices.items) |iv| try skip_set.put(iv, {});

            for (body, 0..) |instr, idx| {
                if (!skip_set.contains(idx)) try new_instructions.append(allocator, instr);
            }

            for (result_slice[back..]) |instr| try new_instructions.append(allocator, instr);

            allocator.free(result_slice);
            result_slice = try new_instructions.toOwnedSlice(allocator);
            modified = true;
        }
    }

    if (!modified) {
        allocator.free(result_slice);
        return null;
    }
    return result_slice;
}

pub const passes = [_]pass.OptimizationPass{
    .{ .name = "licm", .run = loopInvariantCodeMotion },
};
