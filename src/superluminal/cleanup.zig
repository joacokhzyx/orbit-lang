const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass = @import("pass_runner.zig");

fn getRegUses(instr: IRInstruction) [3]?u32 {
    return .{
        if (instr.operand1 == .register) instr.operand1.register else null,
        if (instr.operand2 == .register) instr.operand2.register else null,
        if (instr.operand3 == .register) instr.operand3.register else null,
    };
}

pub fn deadCodeElimination(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var live = std.AutoHashMap(u32, void).init(allocator);
    defer live.deinit();

    for (instructions) |instr| {
        const regs = getRegUses(instr);
        inline for (regs) |reg_opt| {
            if (reg_opt) |reg| try live.put(reg, {});
        }
    }

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var removed = false;
    for (instructions) |instr| {
        const is_alive = if (instr.dest) |dest| blk: {
            if (instr.opcode == .store_var or instr.opcode == .store_field or
                instr.opcode == .call or instr.opcode == .ret or
                instr.opcode == .jump or instr.opcode == .jump_if_false or
                instr.opcode == .label)
                break :blk true;
            break :blk live.contains(dest);
        } else true;

        if (is_alive) {
            try result.append(allocator, instr);
        } else {
            removed = true;
        }
    }

    if (!removed) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub fn copyPropagation(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var replacements = std.AutoHashMap(u32, IRValue).init(allocator);
    defer replacements.deinit();

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var modified = false;

    for (instructions) |instr| {
        var new_instr = instr;

        if (new_instr.operand1 == .register) {
            if (replacements.get(new_instr.operand1.register)) |rep| {
                new_instr.operand1 = rep;
                modified = true;
            }
        }
        if (new_instr.operand2 == .register) {
            if (replacements.get(new_instr.operand2.register)) |rep| {
                new_instr.operand2 = rep;
                modified = true;
            }
        }
        if (new_instr.operand3 == .register) {
            if (replacements.get(new_instr.operand3.register)) |rep| {
                new_instr.operand3 = rep;
                modified = true;
            }
        }

        if (new_instr.opcode == .copy and new_instr.dest != null) {
            try replacements.put(new_instr.dest.?, new_instr.operand1);
        } else if (new_instr.opcode == .store_var) {
            replacements.clearRetainingCapacity();
        }

        try result.append(allocator, new_instr);
    }

    if (!modified) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub const passes = [_]pass.OptimizationPass{
    .{ .name = "dce", .run = deadCodeElimination },
    .{ .name = "copy_prop", .run = copyPropagation },
};
