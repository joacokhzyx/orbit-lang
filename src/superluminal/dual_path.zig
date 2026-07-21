const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRFunction = ir.IRFunction;
const IROpcode = ir.IROpcode;

const MAX_DUALPATH_INSTR: usize = 200;

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
