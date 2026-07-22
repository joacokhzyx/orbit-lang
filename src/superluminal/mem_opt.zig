const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass_runner = @import("pass_runner.zig");

pub fn storeLoadForwarding(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var last_store = std.StringHashMap(u32).init(allocator);
    defer last_store.deinit();

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var modified = false;

    for (instructions) |instr| {
        switch (instr.opcode) {
            .store_var => {
                if (instr.operand1 == .string) {
                    try last_store.put(instr.operand1.string, instr.dest orelse 0);
                }
                try result.append(allocator, instr);
            },
            .load_var => {
                if (instr.operand1 == .string) {
                    if (last_store.get(instr.operand1.string)) |src_reg| {
                        if (instr.dest != null) {
                            var copy = IRInstruction.init(.copy);
                            copy.dest = instr.dest;
                            copy.operand1 = IRValue{ .register = src_reg };
                            try result.append(allocator, copy);
                            modified = true;
                            continue;
                        }
                    }
                }
                try result.append(allocator, instr);
            },
            else => try result.append(allocator, instr),
        }
    }

    if (!modified) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub fn deadStoreElimination(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var last_store_per_var = std.StringHashMap(usize).init(allocator);
    defer last_store_per_var.deinit();

    var has_store_before = std.AutoHashMap(usize, void).init(allocator);
    defer has_store_before.deinit();

    for (instructions, 0..) |instr, i| {
        if (instr.opcode == .store_var and instr.operand1 == .string) {
            const var_name = instr.operand1.string;
            if (last_store_per_var.contains(var_name)) {
                const prev_idx = last_store_per_var.get(var_name).?;
                var is_read = false;
                var j = prev_idx + 1;
                while (j < i) : (j += 1) {
                    const mid = instructions[j];
                    if (mid.opcode == .load_var and mid.operand1 == .string and std.mem.eql(u8, mid.operand1.string, var_name)) {
                        is_read = true;
                        break;
                    }
                }
                if (!is_read) {
                    try has_store_before.put(prev_idx, {});
                }
            }
            try last_store_per_var.put(var_name, i);
        }
    }

    if (has_store_before.count() == 0) return null;

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    for (instructions, 0..) |instr, i| {
        if (has_store_before.contains(i)) continue;
        try result.append(allocator, instr);
    }

    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub fn redundantLoadElimination(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var last_load = std.StringHashMap(u32).init(allocator);
    defer last_load.deinit();

    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var modified = false;

    for (instructions) |instr| {
        switch (instr.opcode) {
            .store_var, .store_field => {
                last_load.clearRetainingCapacity();
                try result.append(allocator, instr);
            },
            .load_var => {
                if (instr.operand1 == .string) {
                    if (last_load.get(instr.operand1.string)) |reg| {
                        if (instr.dest != null) {
                            var copy = IRInstruction.init(.copy);
                            copy.dest = instr.dest;
                            copy.operand1 = IRValue{ .register = reg };
                            try result.append(allocator, copy);
                            modified = true;
                            continue;
                        }
                    }
                    if (instr.dest != null) {
                        try last_load.put(instr.operand1.string, instr.dest.?);
                    }
                }
                try result.append(allocator, instr);
            },
            else => try result.append(allocator, instr),
        }
    }

    if (!modified) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub const passes = [_]pass_runner.OptimizationPass{
    .{ .name = "store_load_forward", .run = storeLoadForwarding },
    .{ .name = "dead_stores", .run = deadStoreElimination },
    .{ .name = "redundant_loads", .run = redundantLoadElimination },
};
