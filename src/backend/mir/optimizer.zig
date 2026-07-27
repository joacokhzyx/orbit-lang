//! orbit/src/backend/mir/optimizer.zig
//!
//! Target-independent MIR Optimization Engine.
//! Performs Constant Folding, Strength Reduction, and Dead Code Elimination.

const std = @import("std");
const mir_mod = @import("mir.zig");
const MirModule = mir_mod.MirModule;
const MirFunction = mir_mod.MirFunction;
const MirBasicBlock = mir_mod.MirBasicBlock;
const MirInstruction = mir_mod.MirInstruction;
const MirOpcode = mir_mod.MirOpcode;
const MirOperand = mir_mod.MirOperand;

pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    /// Optimizes all functions within a MIR module.
    pub fn optimizeModule(self: *Optimizer, module: *MirModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    /// Optimizes a single MIR function through iterative passes.
    pub fn optimizeFunction(self: *Optimizer, func: *MirFunction) !void {
        var changed = true;
        var pass: usize = 0;
        // Limit max optimization passes to 10 to ensure fast compilation
        while (changed and pass < 10) : (pass += 1) {
            changed = false;
            for (func.blocks.items) |*block| {
                if (try self.foldBlockConstants(block, func)) changed = true;
                if (try self.eliminateDeadCode(block, func)) changed = true;
            }
        }
    }

    /// Constant Folding and Strength Reduction.
    fn foldBlockConstants(self: *Optimizer, block: *MirBasicBlock, func: *MirFunction) !bool {
        _ = self;
        _ = func;
        var changed = false;

        for (block.instructions.items) |*instr| {
            switch (instr.opcode) {
                .add => {
                    if (instr.op1 == .imm_int and instr.op2 == .imm_int) {
                        instr.opcode = .const_int;
                        instr.op1 = .{ .imm_int = instr.op1.imm_int + instr.op2.imm_int };
                        instr.op2 = .none;
                        changed = true;
                    }
                },
                .sub => {
                    if (instr.op1 == .imm_int and instr.op2 == .imm_int) {
                        instr.opcode = .const_int;
                        instr.op1 = .{ .imm_int = instr.op1.imm_int - instr.op2.imm_int };
                        instr.op2 = .none;
                        changed = true;
                    }
                },
                .mul => {
                    if (instr.op1 == .imm_int and instr.op2 == .imm_int) {
                        instr.opcode = .const_int;
                        instr.op1 = .{ .imm_int = instr.op1.imm_int * instr.op2.imm_int };
                        instr.op2 = .none;
                        changed = true;
                    } else if (instr.op2 == .imm_int) {
                        // Strength reduction: multiply by power of 2 -> shift left
                        const val = instr.op2.imm_int;
                        if (val == 2) {
                            instr.opcode = .shl;
                            instr.op2 = .{ .imm_int = 1 };
                            changed = true;
                        } else if (val == 4) {
                            instr.opcode = .shl;
                            instr.op2 = .{ .imm_int = 2 };
                            changed = true;
                        } else if (val == 8) {
                            instr.opcode = .shl;
                            instr.op2 = .{ .imm_int = 3 };
                            changed = true;
                        }
                    }
                },
                .and_op => {
                    if (instr.op1 == .imm_bool and instr.op2 == .imm_bool) {
                        instr.opcode = .const_bool;
                        instr.op1 = .{ .imm_bool = instr.op1.imm_bool and instr.op2.imm_bool };
                        instr.op2 = .none;
                        changed = true;
                    }
                },
                .or_op => {
                    if (instr.op1 == .imm_bool and instr.op2 == .imm_bool) {
                        instr.opcode = .const_bool;
                        instr.op1 = .{ .imm_bool = instr.op1.imm_bool or instr.op2.imm_bool };
                        instr.op2 = .none;
                        changed = true;
                    }
                },
                else => {},
            }
        }

        return changed;
    }

    /// Dead Code Elimination pass.
    fn eliminateDeadCode(self: *Optimizer, block: *MirBasicBlock, func: *MirFunction) !bool {
        _ = self;
        _ = func;
        var changed = false;
        var i: usize = 0;
        while (i < block.instructions.items.len) {
            const instr = block.instructions.items[i];
            if (instr.opcode == .nop) {
                _ = block.instructions.orderedRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }
        return changed;
    }
};
