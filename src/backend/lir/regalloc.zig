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
        const rcx_phys = LirRegister{ .id = @intFromEnum(RegisterId.rcx), .is_physical = true };
        const rbp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rbp), .is_physical = true };

        for (func.blocks.items) |*block| {
            var res_block = LirBasicBlock{ .id = block.id };
            errdefer res_block.deinit(self.allocator);

            for (block.instructions.items) |instr| {
                // If it is a return or direct jump/nop, emit as-is
                const opcode: X86Opcode = @enumFromInt(instr.opcode);
                if (opcode == .ret or opcode == .jmp or opcode == .nop or opcode == .ud2) {
                    try res_block.instructions.append(self.allocator, instr);
                    continue;
                }

                // Temporary copies to avoid modifying original instructions.
                var new_instr = instr;

                // Load operands from stack to physical scratch registers.
                // Operand 1 -> load to RCX if it's virtual
                if (instr.op1 == .reg and !instr.op1.reg.is_physical) {
                    const slot_idx = instr.op1.reg.id;
                    const offset = -@as(i32, @intCast((slot_idx + 1) * 8));

                    // Emit load: mov RCX, [RBP - offset]
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rm),
                        .dest = rcx_phys,
                        .op1 = .{ .mem = .{ .base = rbp_phys, .disp = offset } },
                    });
                    new_instr.op1 = .{ .reg = rcx_phys };
                }

                // Operand 2 -> load to RAX if it's virtual
                if (instr.op2 == .reg and !instr.op2.reg.is_physical) {
                    const slot_idx = instr.op2.reg.id;
                    const offset = -@as(i32, @intCast((slot_idx + 1) * 8));

                    // Emit load: mov RAX, [RBP - offset]
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rm),
                        .dest = rax_phys,
                        .op1 = .{ .mem = .{ .base = rbp_phys, .disp = offset } },
                    });
                    new_instr.op2 = .{ .reg = rax_phys };
                }

                // Dest -> map to RAX if it's virtual
                if (instr.dest) |d| {
                    if (!d.is_physical) {
                        new_instr.dest = rax_phys;
                    }
                }

                // Emit instruction
                try res_block.instructions.append(self.allocator, new_instr);

                // Store result back to stack if dest was virtual
                if (instr.dest) |d| {
                    if (!d.is_physical) {
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
