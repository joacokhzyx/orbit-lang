//! orbit/src/backend/lir/printer.zig
//!
//! Human-readable printer for LIR functions.
//! Formats basic blocks, x86-64 mnemonics, registers, memory operands,
//! stack slots and symbols after register allocation.

const std = @import("std");

const lir_mod = @import("lir.zig");
const LirFunction = lir_mod.LirFunction;
const LirBasicBlock = lir_mod.LirBasicBlock;
const LirInstruction = lir_mod.LirInstruction;
const LirOperand = lir_mod.LirOperand;
const LirRegister = lir_mod.LirRegister;

const reg_mod = @import("../x86_64/registers.zig");
const RegisterId = reg_mod.RegisterId;
const XmmRegisterId = reg_mod.XmmRegisterId;

const instr_mod = @import("../x86_64/instruction.zig");
const X86Opcode = instr_mod.X86Opcode;

pub const LirPrinter = struct {
    pub fn printFunction(func: *const LirFunction, writer: anytype) !void {
        try writer.print("fn {s} (stack_size={d}, spill_slots={d}) {{\n", .{
            func.name,
            func.stack_size,
            func.spill_slots,
        });
        if (func.is_route) {
            try writer.print("  ; route {s} {s}\n", .{ func.route_method, func.route_path });
        }

        for (func.blocks.items) |*block| {
            try writer.print("  bb_{d}:\n", .{block.id});
            for (block.instructions.items) |instr| {
                try writer.writeAll("    ");
                if (instr.dest) |d| {
                    try printRegister(d, writer);
                    try writer.writeAll(" = ");
                }
                try writer.print("{s}", .{@tagName(@as(X86Opcode, @enumFromInt(instr.opcode)))});
                try printOperand(instr.op1, writer);
                try printOperand(instr.op2, writer);
                try printOperand(instr.op3, writer);
                try writer.writeAll("\n");
            }
        }
        try writer.writeAll("}\n");
    }

    fn printRegister(reg: LirRegister, writer: anytype) !void {
        if (reg.is_physical) {
            switch (reg.class) {
                .xmm => try writer.print("xmm{d}", .{reg.id}),
                .gp => try writer.print("{s}", .{@tagName(@as(RegisterId, @enumFromInt(@as(u4, @intCast(reg.id)))))}),
            }
        } else {
            try writer.print("v{d}", .{reg.id});
        }
    }

    fn printOperand(op: LirOperand, writer: anytype) !void {
        switch (op) {
            .none => {},
            .reg => |r| {
                try writer.writeAll(" ");
                try printRegister(r, writer);
            },
            .imm_int => |v| try writer.print(" {d}", .{v}),
            .imm_float => |v| try writer.print(" {d}", .{v}),
            .stack_slot => |s| try writer.print(" slot[{d}]", .{s}),
            .mem => |m| {
                try writer.writeAll(" [");
                if (m.base) |b| try printRegister(b, writer);
                if (m.index) |ix| {
                    try writer.writeAll(" + ");
                    try printRegister(ix, writer);
                    if (m.scale != 1) try writer.print("*{d}", .{m.scale});
                }
                if (m.disp != 0) {
                    if (m.base == null and m.index == null) {
                        try writer.print("{d}", .{m.disp});
                    } else {
                        try writer.print(" {s} {d}", .{ if (m.disp < 0) "-" else "+", @abs(m.disp) });
                    }
                }
                try writer.writeAll("]");
            },
            .label => |l| try writer.print(" bb_{d}", .{l}),
            .symbol => |s| try writer.print(" {s}", .{s}),
            .symbol_value => |s| try writer.print(" [{s}]", .{s}),
        }
    }
};