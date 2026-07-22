const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass = @import("pass_runner.zig");

pub fn branchThreading(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var modified = false;
    var result = try allocator.dupe(IRInstruction, instructions);

    var i: usize = 0;
    while (i < result.len) {
        const target = pass.getJumpTarget(result[i]);
        if (target) |label_id| {
            if (pass.findLabel(result, label_id)) |label_pos| {
                if (label_pos + 1 < result.len) {
                    if (result[label_pos + 1].opcode == .jump) {
                        const next_target = pass.getJumpTarget(result[label_pos + 1]);
                        if (next_target) |next_id| {
                            if (next_id != label_id) {
                                if (result[i].opcode == .jump) {
                                    result[i].operand1 = IRValue{ .int = @intCast(next_id) };
                                } else if (result[i].opcode == .jump_if_false) {
                                    result[i].operand2 = IRValue{ .int = @intCast(next_id) };
                                }
                                modified = true;
                            }
                        }
                    }
                }
            }
        }
        i += 1;
    }

    if (!modified) {
        allocator.free(result);
        return null;
    }
    return result;
}

pub fn eliminateDeadLabels(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var referenced = std.AutoHashMap(u32, void).init(allocator);
    defer referenced.deinit();

    for (instructions) |instr| {
        const target = pass.getJumpTarget(instr);
        if (target) |t| try referenced.put(t, {});
    }

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var removed = false;
    for (instructions) |instr| {
        if (instr.opcode == .label) {
            const id = pass.getLabelId(instr);
            if (id) |lid| {
                if (!referenced.contains(lid)) {
                    removed = true;
                    continue;
                }
            }
        }
        try result.append(allocator, instr);
    }

    if (!removed) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub fn eliminateUnreachableBlocks(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var reachable = std.AutoHashMap(usize, void).init(allocator);
    defer reachable.deinit();

    var to_visit = std.ArrayListUnmanaged(usize).empty;
    defer to_visit.deinit(allocator);

    try reachable.put(0, {});
    try to_visit.append(allocator, 0);

    while (to_visit.items.len > 0) {
        const idx_opt = to_visit.pop();
        const idx = idx_opt orelse continue;
        if (idx >= instructions.len) continue;

        const instr = instructions[idx];
        switch (instr.opcode) {
            .jump => {
                const target = pass.getJumpTarget(instr);
                if (target) |t| {
                    if (pass.findLabel(instructions, t)) |pos| {
                        if (!reachable.contains(pos)) {
                            try reachable.put(pos, {});
                            try to_visit.append(allocator, pos);
                        }
                    }
                }
            },
            .jump_if_false => {
                if (idx + 1 < instructions.len and !reachable.contains(idx + 1)) {
                    try reachable.put(idx + 1, {});
                    try to_visit.append(allocator, idx + 1);
                }
                const target = pass.getJumpTarget(instr);
                if (target) |t| {
                    if (pass.findLabel(instructions, t)) |pos| {
                        if (!reachable.contains(pos)) {
                            try reachable.put(pos, {});
                            try to_visit.append(allocator, pos);
                        }
                    }
                }
            },
            .ret => {},
            else => {
                if (idx + 1 < instructions.len and !reachable.contains(idx + 1)) {
                    try reachable.put(idx + 1, {});
                    try to_visit.append(allocator, idx + 1);
                }
            },
        }
    }

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var removed = false;
    for (instructions, 0..) |instr, idx| {
        if (!reachable.contains(idx)) {
            removed = true;
            continue;
        }
        try result.append(allocator, instr);
    }

    if (!removed) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub fn eliminateDeadJumps(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var removed = false;
    var i: usize = 0;
    while (i < instructions.len) {
        if (instructions[i].opcode == .jump) {
            const target = pass.getJumpTarget(instructions[i]);
            if (target) |t| {
                if (pass.findLabel(instructions, t)) |pos| {
                    if (pos == i + 1) {
                        removed = true;
                        i += 1;
                        continue;
                    }
                }
            }
        }
        try result.append(allocator, instructions[i]);
        i += 1;
    }

    if (!removed) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub const passes = [_]pass.OptimizationPass{
    .{ .name = "branch_threading", .run = branchThreading },
    .{ .name = "dead_labels", .run = eliminateDeadLabels },
    .{ .name = "unreachable_blocks", .run = eliminateUnreachableBlocks },
    .{ .name = "dead_jumps", .run = eliminateDeadJumps },
};
