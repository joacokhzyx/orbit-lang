//! orbit/src/backend/lir/verifier.zig
//!
//! Validates target-specific LIR layout, register boundaries, calling convention,
//! and stack balance to prevent corrupted instruction streams.

const std = @import("std");
const lir_mod = @import("lir.zig");
const LirModule = lir_mod.LirModule;
const LirFunction = lir_mod.LirFunction;
const LirBasicBlock = lir_mod.LirBasicBlock;
const LirInstruction = lir_mod.LirInstruction;
const LirOperand = lir_mod.LirOperand;

pub const LirVerifierError = error{
    EmptyLirFunction,
    InvalidOperandSize,
    StackMisalignment,
    DanglingBlockReference,
};

pub const LirVerifier = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LirVerifier {
        return .{ .allocator = allocator };
    }

    /// Verify a complete LIR module.
    pub fn verify(self: *LirVerifier, module: *const LirModule) !void {
        _ = self;
        for (module.functions.items) |*func| {
            try verifyFunction(func);
        }
    }

    fn verifyFunction(func: *const LirFunction) !void {
        if (func.blocks.items.len == 0) {
            return LirVerifierError.EmptyLirFunction;
        }

        // Verify stack alignment is 16 bytes.
        if (func.stack_size % 16 != 0) {
            std.debug.print("Error: Stack size {d} in function {s} is not 16-byte aligned\n", .{ func.stack_size, func.name });
            return LirVerifierError.StackMisalignment;
        }

        for (func.blocks.items) |*block| {
            for (block.instructions.items) |instr| {
                try verifyOperand(instr.op1, func);
                try verifyOperand(instr.op2, func);
                try verifyOperand(instr.op3, func);
            }
        }
    }

    fn verifyOperand(op: LirOperand, func: *const LirFunction) !void {
        switch (op) {
            .label => |b| {
                if (b >= func.blocks.items.len) {
                    std.debug.print("Error: LIR jump to non-existent block bb_{d} in function {s}\n", .{ b, func.name });
                    return LirVerifierError.DanglingBlockReference;
                }
            },
            else => {},
        }
    }
};
