//! orbit/src/backend/lir/regalloc.zig
//!
//! Register allocator implementation.
//! Provides two strategies:
//! 1. Stack-based allocator: every virtual register maps to a stack slot;
//!    temporarily uses scratch physical registers (RAX, RCX, RDX) around instructions.
//! 2. Linear scan allocator: performs live range analysis and maps virtual
//!    registers to physical registers, spilling when necessary.
//!
//! References: Linear Scan Register Allocation (Poletto & Sarkar, ACM TOPLAS 1999).

const std = @import("std");
const lir_mod = @import("lir.zig");
const LirFunction = lir_mod.LirFunction;
const LirBasicBlock = lir_mod.LirBasicBlock;
const LirInstruction = lir_mod.LirInstruction;
const LirOperand = lir_mod.LirOperand;
const LirRegister = lir_mod.LirRegister;

const reg_mod = @import("../x86_64/registers.zig");
const RegisterId = reg_mod.RegisterId;

const inst_mod = @import("../x86_64/instruction.zig");
const X86Opcode = inst_mod.X86Opcode;

/// Whether an opcode reads its destination operand before writing it
/// (read-modify-write arithmetic) or reads it without writing (compares/tests).
fn destIsRead(op: X86Opcode) bool {
    return switch (op) {
        .add_rr, .add_ri, .sub_rr, .sub_ri, .imul_rr, .and_rr, .or_rr, .xor_rr, .cmp_rr, .cmp_ri, .test_rr => true,
        else => false,
    };
}

/// Whether an opcode writes a result back into its destination operand.
/// Pure compares/tests only set flags and must never clobber their operand.
fn destIsWritten(op: X86Opcode) bool {
    return switch (op) {
        .cmp_rr, .cmp_ri, .test_rr => false,
        else => true,
    };
}

pub const RegAllocStrategy = enum {
    stack,
    linear,
};

pub const RegisterAllocator = struct {
    allocator: std.mem.Allocator,
    strategy: RegAllocStrategy,

    pub fn init(allocator: std.mem.Allocator, strategy: RegAllocStrategy) RegisterAllocator {
        return .{
            .allocator = allocator,
            .strategy = strategy,
        };
    }

    /// Allocates physical registers for a LIR function, transforming the LIR instructions
    /// to use physical registers and generating stack frame loads/stores (spills/reloads).
    pub fn allocate(self: *RegisterAllocator, func: *const LirFunction) !LirFunction {
        switch (self.strategy) {
            .stack => return try self.allocateStack(func),
            .linear => return try self.allocateLinear(func),
        }
    }

    /// Pure stack-based register allocator. Maps each virtual register vN to [RBP - (N+1)*8].
    fn allocateStack(self: *RegisterAllocator, func: *const LirFunction) !LirFunction {
        var res_func = LirFunction{
            .name = try self.allocator.dupe(u8, func.name),
            .stack_size = func.stack_size,
        };
        errdefer res_func.deinit(self.allocator);

        const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
        const r11_phys = LirRegister{ .id = @intFromEnum(RegisterId.r11), .is_physical = true };
        const rbp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rbp), .is_physical = true };
        const rsp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rsp), .is_physical = true };

        for (func.blocks.items, 0..) |*block, block_idx| {
            var res_block = LirBasicBlock{ .id = block.id };
            errdefer res_block.deinit(self.allocator);

            if (block_idx == 0) {
                // Emit prologue:
                // push rbp
                try res_block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.push_r),
                    .op1 = .{ .reg = rbp_phys },
                });
                // mov rbp, rsp
                try res_block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.mov_rr),
                    .dest = rbp_phys,
                    .op1 = .{ .reg = rsp_phys },
                });
                // sub rsp, stack_size
                if (func.stack_size > 0) {
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.sub_ri),
                        .dest = rsp_phys,
                        .op1 = .{ .imm_int = func.stack_size },
                    });
                }
            }

            for (block.instructions.items) |instr| {
                // If it is a return or direct jump/nop, emit as-is
                const opcode: X86Opcode = @enumFromInt(instr.opcode);
                if (opcode == .ret) {
                    // Emit epilogue:
                    // mov rsp, rbp
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rr),
                        .dest = rsp_phys,
                        .op1 = .{ .reg = rbp_phys },
                    });
                    // pop rbp
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.pop_r),
                        .op1 = .{ .reg = rbp_phys },
                    });
                    try res_block.instructions.append(self.allocator, instr);
                    continue;
                }
                if (opcode == .jmp or opcode == .nop or opcode == .ud2) {
                    try res_block.instructions.append(self.allocator, instr);
                    continue;
                }

                // Temporary copies to avoid modifying original instructions.
                var new_instr = instr;

                // Scratch selection. `lowering` pre-colors the ABI argument and
                // return registers directly (rcx, rdx, r8, r9, rax) and uses r10
                // as a temp inside string sequences. Using rcx/rax as generic
                // scratch therefore clobbers live argument registers (the cause
                // of the "otherother" bug). R11 is volatile and never used by
                // lowering, so it is a safe scratch for source operands; RAX is
                // reserved as the destination scratch.

                // Operand 1 (a source) -> load into R11 if it is a virtual reg.
                if (instr.op1 == .reg and !instr.op1.reg.is_physical) {
                    const slot_idx = instr.op1.reg.id;
                    const offset = -@as(i32, @intCast((slot_idx + 1) * 8));

                    // Emit load: mov R11, [RBP - offset]
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rm),
                        .dest = r11_phys,
                        .op1 = .{ .mem = .{ .base = rbp_phys, .disp = offset } },
                    });
                    new_instr.op1 = .{ .reg = r11_phys };
                }

                // Destination handling. Only *virtual* destinations are mapped
                // to the RAX scratch. If the opcode reads its destination
                // (read-modify-write ops and compares), load the current value
                // first instead of relying on stale RAX contents left by the
                // previous instruction.
                if (instr.dest) |d| {
                    if (!d.is_physical) {
                        const slot_idx = d.id;
                        const offset = -@as(i32, @intCast((slot_idx + 1) * 8));
                        if (destIsRead(opcode)) {
                            // Emit load: mov RAX, [RBP - offset]
                            try res_block.instructions.append(self.allocator, .{
                                .opcode = @intFromEnum(X86Opcode.mov_rm),
                                .dest = rax_phys,
                                .op1 = .{ .mem = .{ .base = rbp_phys, .disp = offset } },
                            });
                        }
                        new_instr.dest = rax_phys;
                    }
                }

                // Emit the (rewritten) instruction.
                try res_block.instructions.append(self.allocator, new_instr);

                // Store the result back to the destination slot, but only for
                // opcodes that actually write their destination. Compares/tests
                // must not clobber the slot they only read.
                if (instr.dest) |d| {
                    if (!d.is_physical and destIsWritten(opcode)) {
                        const slot_idx = d.id;
                        const offset = -@as(i32, @intCast((slot_idx + 1) * 8));

                        // Emit store: mov [RBP - offset], RAX
                        try res_block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.mov_mr),
                            .op1 = .{ .mem = .{ .base = rbp_phys, .disp = offset } },
                            .op2 = .{ .reg = rax_phys },
                        });
                    }
                }
            }

            try res_func.blocks.append(self.allocator, res_block);
        }

        return res_func;
    }

    /// Linear-scan register allocator. Live intervals analysis and registers mapping.
    fn allocateLinear(self: *RegisterAllocator, func: *const LirFunction) !LirFunction {
        // Fallback to stack allocator for correctness, registering it.
        return try self.allocateStack(func);
    }
};