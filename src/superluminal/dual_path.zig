const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRFunction = ir.IRFunction;
const IRModule = ir.IRModule;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;

const MAX_DUALPATH_INSTR: usize = 200;

pub const DUALPATH_TAG = "_orbit_dualpath_";

pub fn qualifies(func: IRFunction) bool {
    if (func.instructions.items.len > MAX_DUALPATH_INSTR) return false;
    if (func.instructions.items.len < 4) return false;

    for (func.instructions.items) |instr| {
        switch (instr.opcode) {
            .load_field, .store_field, .list_get, .map_get, .map_set => return true,
            else => {},
        }
    }

    return false;
}

pub const DualPathPass = struct {
    allocator: std.mem.Allocator,
    transformed_count: usize,

    pub fn init(allocator: std.mem.Allocator) DualPathPass {
        return .{
            .allocator = allocator,
            .transformed_count = 0,
        };
    }

    pub fn optimize(self: *DualPathPass, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            if (isDualPath(func.*)) continue;
            if (qualifies(func.*)) {
                const marker = blk: {
                    var instr = IRInstruction.init(.nop);
                    instr.operand1 = IRValue{ .symbol = DUALPATH_TAG };
                    break :blk instr;
                };
                try func.instructions.insert(self.allocator, 0, marker);
                self.transformed_count += 1;
            }
        }
    }
};

pub fn isDualPath(func: IRFunction) bool {
    if (func.instructions.items.len == 0) return false;
    const first = func.instructions.items[0];
    if (first.opcode != .nop) return false;
    if (first.operand1 != .symbol) return false;
    return std.mem.eql(u8, first.operand1.symbol, DUALPATH_TAG);
}
