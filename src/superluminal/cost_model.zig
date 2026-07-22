const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;

pub const Cost = struct {
    alu: u32 = 0,
    mem_read: u32 = 0,
    mem_write: u32 = 0,
    branch: u32 = 0,
    reg_assign: u32 = 0,
    label: u32 = 0,
    call: u32 = 0,

    pub fn total(self: Cost) f64 {
        return @as(f64, @floatFromInt(self.alu)) * 1.0 + @as(f64, @floatFromInt(self.mem_read)) * 3.0 + @as(f64, @floatFromInt(self.mem_write)) * 3.0 + @as(f64, @floatFromInt(self.branch)) * 10.0 + @as(f64, @floatFromInt(self.reg_assign)) * 0.5 + @as(f64, @floatFromInt(self.label)) * 2.0 + @as(f64, @floatFromInt(self.call)) * 15.0;
    }

    pub fn format(self: Cost, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Cost{{ alu={d} mem_r={d} mem_w={d} branch={d} reg={d} label={d} call={d} total={d:.1} }}", .{
            self.alu, self.mem_read, self.mem_write, self.branch, self.reg_assign, self.label, self.call, self.total(),
        });
    }
};

pub fn evaluate(instr: IRInstruction) Cost {
    var c = Cost{};
    switch (instr.opcode) {
        .add, .sub, .mul, .div, .mod => c.alu = 1,
        .eq, .ne, .lt, .le, .gt, .ge => c.alu = 1,
        .and_op, .or_op, .not_op, .neg => c.alu = 1,

        .load_var, .copy => {
            c.reg_assign = 1;
            c.mem_read = 1;
        },
        .load_field => {
            c.reg_assign = 1;
            c.mem_read = 2;
        },
        .store_var, .decl_var => {
            c.mem_write = 1;
        },
        .store_field => {
            c.mem_read = 1;
            c.mem_write = 2;
        },
        .load_const => {},
        .arg => c.reg_assign = 1,
        .call => c.call = 1,
        .ret => c.mem_write = 1,
        .jump => c.branch = 1,
        .jump_if_false => c.branch = 2,
        .label => c.label = 1,
        .begin_block, .end_block => {},
        else => c.alu = 1,
    }
    return c;
}

pub fn evaluateSlice(instructions: []const IRInstruction) Cost {
    var total = Cost{};
    for (instructions) |instr| {
        const c = evaluate(instr);
        total.alu += c.alu;
        total.mem_read += c.mem_read;
        total.mem_write += c.mem_write;
        total.branch += c.branch;
        total.reg_assign += c.reg_assign;
        total.label += c.label;
        total.call += c.call;
    }
    return total;
}

pub fn speedupFactor(original: Cost, optimized: Cost) f64 {
    const o = original.total();
    const n = optimized.total();
    if (n == 0) return 100.0;
    return o / n;
}
