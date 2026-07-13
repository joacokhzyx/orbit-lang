//! orbit/src/backend/mir/printer.zig
//!
//! Human-readable printer for MIR functions and modules.
//! Formats basic blocks, instruction mnemonics, operands, and CFG links.

const std = @import("std");
const mir_mod = @import("mir.zig");
const MirModule = mir_mod.MirModule;
const MirFunction = mir_mod.MirFunction;
const MirBasicBlock = mir_mod.MirBasicBlock;
const MirInstruction = mir_mod.MirInstruction;
const MirOpcode = mir_mod.MirOpcode;
const MirOperand = mir_mod.MirOperand;

pub const MirPrinter = struct {
    pub fn printModule(module: *const MirModule, writer: anytype) !void {
        for (module.functions.items) |*func| {
            try printFunction(func, writer);
            try writer.writeAll("\n");
        }
    }

    pub fn printFunction(func: *const MirFunction, writer: anytype) !void {
        try writer.print("fn {s}(", .{func.name});
        for (func.param_types, 0..) |pt, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("p{d}: {s}", .{ i, @tagName(pt) });
        }
        try writer.print(") -> {s} {{\n", .{@tagName(func.return_type)});

        for (func.blocks.items) |*block| {
            try writer.print("  {s}:\n", .{block.name});

            // Print CFG Predecessors
            if (block.predecessors.items.len > 0) {
                try writer.writeAll("    ; preds: ");
                for (block.predecessors.items, 0..) |pred_id, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("bb_{d}", .{pred_id});
                }
                try writer.writeAll("\n");
            }

            for (block.instructions.items) |instr| {
                try writer.writeAll("    ");
                if (instr.dest) |d| {
                    try writer.print("r{d} = ", .{d});
                }
                try writer.print("{s}", .{@tagName(instr.opcode)});

                try printOperand(instr.op1, writer);
                try printOperand(instr.op2, writer);
                try printOperand(instr.op3, writer);
                try writer.writeAll("\n");
            }

            // Print CFG Successors
            if (block.successors.items.len > 0) {
                try writer.writeAll("    ; succs: ");
                for (block.successors.items, 0..) |succ_id, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("bb_{d}", .{succ_id});
                }
                try writer.writeAll("\n");
            }
        }
        try writer.writeAll("}\n");
    }

    fn printOperand(op: MirOperand, writer: anytype) !void {
        switch (op) {
            .none => {},
            .reg => |r| try writer.print(" r{d}", .{r}),
            .imm_int => |v| try writer.print(" {d}", .{v}),
            .imm_float => |v| try writer.print(" {d}", .{v}),
            .imm_bool => |v| try writer.print(" {s}", .{if (v) "true" else "false"}),
            .imm_str => |v| try writer.print(" \"{s}\"", .{v}),
            .block => |b| try writer.print(" bb_{d}", .{b}),
        }
    }
};
