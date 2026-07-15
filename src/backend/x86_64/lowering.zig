//! orbit/src/backend/x86_64/lowering.zig
//!
//! Lowers target-independent MIR into target-specific x86-64 LIR.
//! Resolves ABI parameter mapping, arithmetic expansion (3-operand to 2-operand),
//! and stack slot allocation for local values.
//!
//! References: AMD64 Architecture Programmer's Manual, Vol 3.

const std = @import("std");
const target_mod = @import("../target.zig");
const Target = target_mod.Target;

const mir_mod = @import("../mir/mir.zig");
const MirFunction = mir_mod.MirFunction;
const MirBasicBlock = mir_mod.MirBasicBlock;
const MirInstruction = mir_mod.MirInstruction;
const MirOperand = mir_mod.MirOperand;

const lir_mod = @import("../lir/lir.zig");
const LirFunction = lir_mod.LirFunction;
const LirBasicBlock = lir_mod.LirBasicBlock;
const LirInstruction = lir_mod.LirInstruction;
const LirOperand = lir_mod.LirOperand;
const LirRegister = lir_mod.LirRegister;

const inst_mod = @import("instruction.zig");
const X86Opcode = inst_mod.X86Opcode;

const reg_mod = @import("registers.zig");
const RegisterId = reg_mod.RegisterId;

pub const Lowering = struct {
    allocator: std.mem.Allocator,
    target: Target,
    arg_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, target: Target) Lowering {
        return .{
            .allocator = allocator,
            .target = target,
            .arg_count = 0,
        };
    }

    fn emitMov(self: *Lowering, block: *LirBasicBlock, dest: LirRegister, src: LirOperand) !void {
        if (src == .reg) {
            try block.instructions.append(self.allocator, .{
                .opcode = @intFromEnum(X86Opcode.mov_rr),
                .dest = dest,
                .op1 = src,
            });
        } else if (src == .imm_int or src == .symbol) {
            try block.instructions.append(self.allocator, .{
                .opcode = @intFromEnum(X86Opcode.mov_ri),
                .dest = dest,
                .op1 = src,
            });
        } else if (src == .mem) {
            try block.instructions.append(self.allocator, .{
                .opcode = @intFromEnum(X86Opcode.mov_rm),
                .dest = dest,
                .op1 = src,
            });
        } else {
            try block.instructions.append(self.allocator, .{
                .opcode = @intFromEnum(X86Opcode.mov_ri),
                .dest = dest,
                .op1 = src,
            });
        }
    }

    /// Lower a MIR function to x86-64 LIR.
    pub fn lowerFunction(self: *Lowering, mir_func: *const MirFunction) !LirFunction {
        var lir_func = LirFunction{
            .name = try self.allocator.dupe(u8, mir_func.name),
        };
        errdefer lir_func.deinit(self.allocator);

        // Preallocate stack size for local registers.
        // For correctness, we place every MIR virtual register in a stack slot.
        // Each register is 8 bytes.
        const reg_count = mir_func.val_types.items.len;
        lir_func.stack_size = @intCast(reg_count * 8);

        // Add ABI-specific shadow space.
        if (self.target.abi == .windows_x64) {
            lir_func.stack_size += 32; // 32 bytes shadow space
        }

        // Align stack to 16 bytes.
        lir_func.stack_size = (lir_func.stack_size + 15) & ~@as(u32, 15);

        for (mir_func.blocks.items) |*mir_block| {
            var lir_block = LirBasicBlock{
                .id = mir_block.id,
            };
            errdefer lir_block.deinit(self.allocator);

            for (mir_block.instructions.items) |mir_instr| {
                try self.lowerInstruction(mir_instr, &lir_block, mir_func);
            }

            try lir_func.blocks.append(self.allocator, lir_block);
        }

        // Emit parameter passing copies at the beginning of block 0
        if (lir_func.blocks.items.len > 0) {
            var entry_block = &lir_func.blocks.items[0];
            
            const abi_regs: []const RegisterId = if (self.target.abi == .windows_x64)
                &.{ .rcx, .rdx, .r8, .r9 }
            else
                &.{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

            const num_params = mir_func.param_types.len;
            const start_reg_id = mir_func.val_types.items.len - num_params;

            var param_idx: usize = 0;
            while (param_idx < num_params) : (param_idx += 1) {
                const param_reg_id = start_reg_id + param_idx;
                const dest_reg = LirRegister{ .id = @intCast(param_reg_id), .is_physical = false };
                
                if (param_idx < abi_regs.len) {
                    const src_phys_reg = LirRegister{ .id = @intFromEnum(abi_regs[param_idx]), .is_physical = true };
                    // Prepend mov dest_reg, src_phys_reg
                    try entry_block.instructions.insert(self.allocator, param_idx, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rr),
                        .dest = dest_reg,
                        .op1 = .{ .reg = src_phys_reg },
                    });
                } else {
                    // Parameter passed on stack.
                    // The stack parameters are located at [RBP + 16 + (param_idx - abi_regs.len)*8]
                    const disp: i32 = if (self.target.abi == .windows_x64)
                        @intCast(16 + param_idx * 8)
                    else
                        @intCast(16 + (param_idx - abi_regs.len) * 8);

                    const rbp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rbp), .is_physical = true };
                    // Prepend mov dest_reg, [RBP + disp]
                    try entry_block.instructions.insert(self.allocator, param_idx, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rm),
                        .dest = dest_reg,
                        .op1 = .{ .mem = .{ .base = rbp_phys, .disp = disp } },
                    });
                }
            }
        }

        if (mir_func.is_route) {
            lir_func.is_route = true;
            lir_func.route_method = try self.allocator.dupe(u8, mir_func.route_method);
            lir_func.route_path = try self.allocator.dupe(u8, mir_func.route_path);
        }

        return lir_func;
    }

    fn mapReg(reg: u32) LirRegister {
        return .{ .id = reg, .is_physical = false };
    }

    fn mapOperand(self: *Lowering, op: MirOperand) LirOperand {
        _ = self;
        return switch (op) {
            .none => .none,
            .reg => |r| .{ .reg = mapReg(r) },
            .imm_int => |v| .{ .imm_int = v },
            .imm_float => |v| .{ .imm_float = v },
            .imm_bool => |v| .{ .imm_int = if (v) 1 else 0 },
            .imm_str => |v| .{ .symbol = v }, // Lower to string symbol address reference
            .block => |b| .{ .label = b },
        };
    }

    fn lowerInstruction(self: *Lowering, mir_instr: MirInstruction, block: *LirBasicBlock, mir_func: *const MirFunction) !void {
        const op1_lir = self.mapOperand(mir_instr.op1);
        const op2_lir = self.mapOperand(mir_instr.op2);

        switch (mir_instr.opcode) {
            .nop => {},
            .copy => {
                const dest = mapReg(mir_instr.dest.?);
                try self.emitMov(block, dest, op1_lir);
            },
            .add => {
                const dest = mapReg(mir_instr.dest.?);
                const dest_type = mir_func.val_types.items[mir_instr.dest.?];
                if (dest_type == .string) {
                    const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                    const arg1_reg = LirRegister{ .id = @intFromEnum(arg_regs[0]), .is_physical = true };
                    const arg2_reg = LirRegister{ .id = @intFromEnum(arg_regs[1]), .is_physical = true };
                    if (op1_lir == .reg and op2_lir == .reg and op1_lir.reg.id == arg2_reg.id and op2_lir.reg.id == arg1_reg.id) {
                        const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };
                        try self.emitMov(block, r10_phys, op2_lir);
                        try self.emitMov(block, arg2_reg, op1_lir);
                        try self.emitMov(block, arg1_reg, .{ .reg = r10_phys });
                    } else if (op2_lir == .reg and op2_lir.reg.id == arg1_reg.id) {
                        try self.emitMov(block, arg2_reg, op2_lir);
                        try self.emitMov(block, arg1_reg, op1_lir);
                    } else if (op1_lir == .reg and op1_lir.reg.id == arg2_reg.id) {
                        try self.emitMov(block, arg1_reg, op1_lir);
                        try self.emitMov(block, arg2_reg, op2_lir);
                    } else {
                        try self.emitMov(block, arg1_reg, op1_lir);
                        try self.emitMov(block, arg2_reg, op2_lir);
                    }
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.call),
                        .op1 = .{ .symbol = "orbit_string_concat" },
                    });
                    const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                } else {
                    try self.emitMov(block, dest, op1_lir);
                    if (op2_lir == .reg) {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.add_rr),
                            .dest = dest,
                            .op1 = op2_lir,
                        });
                    } else {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.add_ri),
                            .dest = dest,
                            .op1 = op2_lir,
                        });
                    }
                }
            },
            .sub => {
                const dest = mapReg(mir_instr.dest.?);
                try self.emitMov(block, dest, op1_lir);
                if (op2_lir == .reg) {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.sub_rr),
                        .dest = dest,
                        .op1 = op2_lir,
                    });
                } else {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.sub_ri),
                        .dest = dest,
                        .op1 = op2_lir,
                    });
                }
            },
            .mul => {
                const dest = mapReg(mir_instr.dest.?);
                try self.emitMov(block, dest, op1_lir);
                if (op2_lir == .reg) {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.imul_rr),
                        .dest = dest,
                        .op1 = op2_lir,
                    });
                } else {
                    // imul reg, imm: materialize the immediate in R10, then imul_rr.
                    const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.imul_rr),
                        .dest = dest,
                        .op1 = .{ .reg = r10_phys },
                    });
                }
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const dest = mapReg(mir_instr.dest.?);
                
                var rhs_val = op2_lir;
                if (op2_lir == .symbol) {
                    const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    rhs_val = .{ .reg = r10_phys };
                }

                var is_string_cmp = false;
                if (mir_instr.opcode == .eq or mir_instr.opcode == .ne) {
                    if (mir_instr.op1 == .reg) {
                        if (mir_func.val_types.items[mir_instr.op1.reg] == .string) {
                            is_string_cmp = true;
                        }
                    } else if (mir_instr.op1 == .imm_str) {
                        is_string_cmp = true;
                    }
                }

                if (is_string_cmp) {
                    const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                    const arg1_reg = LirRegister{ .id = @intFromEnum(arg_regs[0]), .is_physical = true };
                    const arg2_reg = LirRegister{ .id = @intFromEnum(arg_regs[1]), .is_physical = true };
                    if (op1_lir == .reg and rhs_val == .reg and op1_lir.reg.id == arg2_reg.id and rhs_val.reg.id == arg1_reg.id) {
                        const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };
                        try self.emitMov(block, r10_phys, rhs_val);
                        try self.emitMov(block, arg2_reg, op1_lir);
                        try self.emitMov(block, arg1_reg, .{ .reg = r10_phys });
                    } else if (rhs_val == .reg and rhs_val.reg.id == arg1_reg.id) {
                        try self.emitMov(block, arg2_reg, rhs_val);
                        try self.emitMov(block, arg1_reg, op1_lir);
                    } else if (op1_lir == .reg and op1_lir.reg.id == arg2_reg.id) {
                        try self.emitMov(block, arg1_reg, op1_lir);
                        try self.emitMov(block, arg2_reg, rhs_val);
                    } else {
                        try self.emitMov(block, arg1_reg, op1_lir);
                        try self.emitMov(block, arg2_reg, rhs_val);
                    }
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.call),
                        .op1 = .{ .symbol = "strcmp" },
                    });
                    const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.cmp_ri),
                        .dest = rax_phys,
                        .op1 = .{ .imm_int = 0 },
                    });
                    const set_opcode = switch (mir_instr.opcode) {
                        .eq => X86Opcode.sete_r,
                        .ne => X86Opcode.setne_r,
                        else => unreachable,
                    };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(set_opcode),
                        .dest = dest,
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.movzx_rr),
                        .dest = dest,
                        .op1 = .{ .reg = dest },
                    });
                } else {
                    var lhs_reg = dest;
                    if (op1_lir != .reg) {
                        try self.emitMov(block, dest, op1_lir);
                    } else {
                        lhs_reg = op1_lir.reg;
                    }

                    if (rhs_val == .imm_int) {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.cmp_ri),
                            .dest = lhs_reg,
                            .op1 = rhs_val,
                        });
                    } else {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.cmp_rr),
                            .dest = lhs_reg,
                            .op1 = rhs_val,
                        });
                    }

                    const set_opcode = switch (mir_instr.opcode) {
                        .eq => X86Opcode.sete_r,
                        .ne => X86Opcode.setne_r,
                        .lt => X86Opcode.setl_r,
                        .le => X86Opcode.setle_r,
                        .gt => X86Opcode.setg_r,
                        .ge => X86Opcode.setge_r,
                        else => unreachable,
                    };

                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(set_opcode),
                        .dest = dest,
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.movzx_rr),
                        .dest = dest,
                        .op1 = .{ .reg = dest },
                    });
                }
            },
            .jmp => {
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.jmp),
                    .op1 = op1_lir,
                });
            },
            .jmp_if => {
                // MIR jmp_if cond target -> cmp cond, 0 -> je target
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.cmp_ri),
                    .dest = op1_lir.reg,
                    .op1 = .{ .imm_int = 0 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.je),
                    .op1 = op2_lir,
                });
            },
            .arg => {
                const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                if (self.arg_count < arg_regs.len) {
                    const arg_reg_id = arg_regs[self.arg_count];
                    const phys_reg = LirRegister{
                        .id = @intFromEnum(arg_reg_id),
                        .is_physical = true,
                    };
                    try self.emitMov(block, phys_reg, op1_lir);
                } else {
                    @panic("Stack-passed arguments (>4/6) not yet implemented in native backend");
                }
                self.arg_count += 1;
            },
            .ret => {
                if (mir_instr.op1 != .none) {
                    // RAX is the standard return register on both Windows and SysV ABI.
                    const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                    try self.emitMov(block, rax_phys, op1_lir);
                }
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.ret),
                });
            },
            .call => {
                // Reset argument count for the next call sequence
                self.arg_count = 0;

                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.call),
                    .op1 = op1_lir,
                });

                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                }
            },
            .div, .mod => {
                const dest = mapReg(mir_instr.dest.?);
                const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                const rdx_phys = LirRegister{ .id = @intFromEnum(RegisterId.rdx), .is_physical = true };
                const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };

                // Dividend -> RAX.
                try self.emitMov(block, rax_phys, op1_lir);
                // Divisor -> R10 (never an implicit operand of idiv).
                try self.emitMov(block, r10_phys, op2_lir);
                // Sign-extend RAX into RDX:RAX.
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.cqo),
                });
                // idiv r10 -> quotient in RAX, remainder in RDX.
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.idiv_r),
                    .op1 = .{ .reg = r10_phys },
                });
                const result_reg = if (mir_instr.opcode == .div) rax_phys else rdx_phys;
                try self.emitMov(block, dest, .{ .reg = result_reg });
            },
            .neg, .not_op => {
                const dest = mapReg(mir_instr.dest.?);
                const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                try self.emitMov(block, rax_phys, op1_lir);
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(if (mir_instr.opcode == .neg) X86Opcode.neg_r else X86Opcode.not_r),
                    .dest = rax_phys,
                });
                try self.emitMov(block, dest, .{ .reg = rax_phys });
            },
            .shl, .shr => {
                const dest = mapReg(mir_instr.dest.?);
                const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
                const rcx_phys = LirRegister{ .id = @intFromEnum(RegisterId.rcx), .is_physical = true };
                // Value -> RAX, shift count -> CL (RCX).
                try self.emitMov(block, rax_phys, op1_lir);
                try self.emitMov(block, rcx_phys, op2_lir);
                try block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(if (mir_instr.opcode == .shl) X86Opcode.shl_r else X86Opcode.shr_r),
                    .dest = rax_phys,
                });
                try self.emitMov(block, dest, .{ .reg = rax_phys });
            },
            .and_op, .or_op, .xor_op => {
                const dest = mapReg(mir_instr.dest.?);
                try self.emitMov(block, dest, op1_lir);
                const rr_op = switch (mir_instr.opcode) {
                    .and_op => X86Opcode.and_rr,
                    .or_op => X86Opcode.or_rr,
                    .xor_op => X86Opcode.xor_rr,
                    else => unreachable,
                };
                if (op2_lir == .reg) {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(rr_op),
                        .dest = dest,
                        .op1 = op2_lir,
                    });
                } else {
                    // No reg,imm form for these; materialize the immediate in R10.
                    const r10_phys = LirRegister{ .id = @intFromEnum(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(rr_op),
                        .dest = dest,
                        .op1 = .{ .reg = r10_phys },
                    });
                }
            },
            else => {},
        }
    }
};
