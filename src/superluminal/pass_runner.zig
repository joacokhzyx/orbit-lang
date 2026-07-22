const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;

pub const OptimizationPass = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction,
};

pub const FixedPointResult = struct {
    instructions: []const IRInstruction,
    passes_run: usize,
    iterations: usize,
    changes_made: bool,
};

pub fn runFixedPoint(allocator: std.mem.Allocator, instructions: []const IRInstruction, passes: []const OptimizationPass, max_iterations: usize) !FixedPointResult {
    var current = try allocator.dupe(IRInstruction, instructions);
    errdefer allocator.free(current);

    var total_passes: usize = 0;
    var iteration: usize = 0;
    var changed = true;

    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;
        for (passes) |pass| {
            const result = try pass.run(allocator, current);
            if (result) |new_instrs| {
                allocator.free(current);
                current = new_instrs;
                changed = true;
                total_passes += 1;
            }
        }
    }

    return FixedPointResult{
        .instructions = current,
        .passes_run = total_passes,
        .iterations = iteration + 1,
        .changes_made = changed,
    };
}

pub fn findLabel(instructions: []const IRInstruction, label_id: u32) ?usize {
    for (instructions, 0..) |instr, i| {
        if (instr.opcode == .label) {
            if (instr.operand1 == .int and instr.operand1.int == label_id) return i;
            if (instr.operand1 == .string) {
                const s = instr.operand1.string;
                if (s.len > 0) {
                    const val = std.fmt.parseInt(u32, s, 10) catch continue;
                    if (val == label_id) return i;
                }
            }
        }
    }
    return null;
}

pub fn getLabelId(instr: IRInstruction) ?u32 {
    if (instr.opcode != .label) return null;
    if (instr.operand1 == .int) return @intCast(instr.operand1.int);
    if (instr.operand1 == .string) {
        return std.fmt.parseInt(u32, instr.operand1.string, 10) catch null;
    }
    return null;
}

pub fn getJumpTarget(instr: IRInstruction) ?u32 {
    if (instr.opcode == .jump) {
        if (instr.operand1 == .int) return @intCast(instr.operand1.int);
    }
    if (instr.opcode == .jump_if_false) {
        if (instr.operand2 == .int) return @intCast(instr.operand2.int);
    }
    return null;
}
