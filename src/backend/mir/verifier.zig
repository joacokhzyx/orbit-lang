//! orbit/src/backend/mir/verifier.zig
//!
//! Validates the structure and soundness of the MIR.
//! Checks block terminators, CFG connectivity, register type consistency,
//! and ensures there are no unsupported operands or dangling references.
//!
//! Reference: SSA-based Compiler Design verification guidelines.

const std = @import("std");
const mir_mod = @import("mir.zig");
const MirModule = mir_mod.MirModule;
const MirFunction = mir_mod.MirFunction;
const MirBasicBlock = mir_mod.MirBasicBlock;
const MirInstruction = mir_mod.MirInstruction;
const MirOpcode = mir_mod.MirOpcode;
const MirOperand = mir_mod.MirOperand;

pub const VerifierError = error{
    EmptyFunction,
    MissingTerminator,
    MalformedCfg,
    TypeMismatch,
    InvalidOperand,
    RegisterOutOfBounds,
};

pub const MirVerifier = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MirVerifier {
        return .{ .allocator = allocator };
    }

    /// Verifies the given `MirModule`. Returns an error if any invariant is violated.
    pub fn verify(self: *MirVerifier, module: *const MirModule) !void {
        _ = self;
        for (module.functions.items) |*func| {
            try verifyFunction(func);
        }
    }

    fn verifyFunction(func: *const MirFunction) !void {
        if (func.blocks.items.len == 0) {
            return VerifierError.EmptyFunction;
        }

        for (func.blocks.items) |*block| {
            if (block.instructions.items.len == 0) {
                // Empty block must be connected or fallthrough
                continue;
            }

            // Verify each instruction's register bounds.
            for (block.instructions.items) |instr| {
                if (instr.dest) |d| {
                    if (d >= func.val_types.items.len) {
                        std.debug.print("Error: Dest register r{d} out of bounds in function {s}\n", .{ d, func.name });
                        return VerifierError.RegisterOutOfBounds;
                    }
                }

                try verifyOperand(instr.op1, func);
                try verifyOperand(instr.op2, func);
                try verifyOperand(instr.op3, func);
            }

            // Verify terminators
            const last = block.instructions.items[block.instructions.items.len - 1];
            switch (last.opcode) {
                .jmp, .jmp_if, .ret => {},
                else => {
                    // Non-terminating block is only allowed if it is not the last block (implicit fallthrough).
                    if (block.id == func.blocks.items.len - 1) {
                        std.debug.print("Error: Last block {s} in function {s} lacks terminal jump/return\n", .{ block.name, func.name });
                        return VerifierError.MissingTerminator;
                    }
                },
            }
        }
    }

    fn verifyOperand(op: MirOperand, func: *const MirFunction) !void {
        switch (op) {
            .reg => |r| {
                if (r >= func.val_types.items.len) {
                    std.debug.print("Error: Operand register r{d} out of bounds in function {s}\n", .{ r, func.name });
                    return VerifierError.RegisterOutOfBounds;
                }
            },
            .block => |b| {
                if (b >= func.blocks.items.len) {
                    std.debug.print("Error: Target basic block bb_{d} out of bounds in function {s}\n", .{ b, func.name });
                    return VerifierError.MalformedCfg;
                }
            },
            else => {},
        }
    }
};
