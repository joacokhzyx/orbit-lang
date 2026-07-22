const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass = @import("pass_runner.zig");

const ConstMap = std.AutoHashMap(u32, i64);

fn getReg(val: IRValue) ?u32 {
    return switch (val) {
        .register => val.register,
        else => null,
    };
}

fn resolveConst(const_map: *ConstMap, val: IRValue) ?i64 {
    return switch (val) {
        .int => val.int,
        .register => const_map.get(val.register),
        else => null,
    };
}

fn tryFoldConstant(const_map: *ConstMap, instr: IRInstruction) ?i64 {
    const dest = instr.dest orelse return null;
    _ = dest;
    switch (instr.opcode) {
        .add => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return a.? + b.?;
        },
        .sub => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return a.? - b.?;
        },
        .mul => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return a.? * b.?;
        },
        .div => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null and b.? != 0) return @divTrunc(a.?, b.?);
        },
        .mod => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null and b.? != 0) return @mod(a.?, b.?);
        },
        .neg => {
            const a = resolveConst(const_map, instr.operand1);
            if (a != null) return -a.?;
        },
        .not_op => {
            const a = resolveConst(const_map, instr.operand1);
            if (a != null) return if (a.? == 0) 1 else 0;
        },
        .and_op => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return a.? & b.?;
        },
        .or_op => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return a.? | b.?;
        },
        .eq => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? == b.?) 1 else 0;
        },
        .ne => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? != b.?) 1 else 0;
        },
        .lt => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? < b.?) 1 else 0;
        },
        .le => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? <= b.?) 1 else 0;
        },
        .gt => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? > b.?) 1 else 0;
        },
        .ge => {
            const a = resolveConst(const_map, instr.operand1);
            const b = resolveConst(const_map, instr.operand2);
            if (a != null and b != null) return if (a.? >= b.?) 1 else 0;
        },
        else => {},
    }
    return null;
}

fn hasSideEffects(opcode: IROpcode) bool {
    return switch (opcode) {
        .store_var, .store_field, .call, .db_set, .list_push, .list_set, .map_set, .map_delete => true,
        else => false,
    };
}

pub fn constantPropagation(allocator: std.mem.Allocator, instructions: []const IRInstruction) anyerror!?[]IRInstruction {
    var result = std.ArrayListUnmanaged(IRInstruction).empty;
    errdefer result.deinit(allocator);

    var const_map = ConstMap.init(allocator);
    defer const_map.deinit();

    var modified = false;

    var i: usize = 0;
    while (i < instructions.len) {
        const instr = instructions[i];

        if (instr.opcode == .load_const and instr.dest != null) {
            if (instr.operand1 == .int) {
                try const_map.put(instr.dest.?, instr.operand1.int);
            }
        }

        if (instr.opcode == .jump_if_false) {
            const cond_reg = getReg(instr.operand1);
            if (cond_reg) |cr| {
                if (const_map.contains(cr)) {
                    modified = true;
                    i += 1;
                    continue;
                }
            }
        }

        if (instr.opcode == .jump) {
            const target = pass.getJumpTarget(instr);
            if (target) |t| {
                if (pass.findLabel(instructions, t)) |pos| {
                    if (pos == i + 1) {
                        modified = true;
                        i += 1;
                        continue;
                    }
                }
            }
        }

        if (instr.dest != null) {
            if (tryFoldConstant(&const_map, instr)) |folded| {
                var load = IRInstruction.init(.load_const);
                load.dest = instr.dest;
                load.operand1 = IRValue{ .int = folded };
                try result.append(allocator, load);
                try const_map.put(instr.dest.?, folded);
                modified = true;
                i += 1;
                continue;
            }
        }

        try result.append(allocator, instr);

        if (hasSideEffects(instr.opcode)) {
            const_map.clearRetainingCapacity();
        }

        i += 1;
    }

    if (!modified) {
        result.deinit(allocator);
        return null;
    }
    const _slice = try result.toOwnedSlice(allocator);
    return @as(?[]IRInstruction, _slice);
}

pub const passes = [_]pass.OptimizationPass{
    .{ .name = "const_propagation", .run = constantPropagation },
};
