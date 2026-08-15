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
const ValueId = mir_mod.ValueId;

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
    /// Set by `sret_alloc`; while set, `.arg` instructions place arguments at
    /// position 1+ and `.call` loads the hidden sret pointer into arg slot 0.
    sret_pending: bool = false,
    /// Maps tag-name strings ("Foo_TAG_Bar") to their variant index (int),
    /// derived from the IR module's type declarations. Tag constants in the
    /// frontend are emitted as strings; the native lowering resolves them to
    /// the small integers the C runtime stores in `Foo_Tag tag`.
    tag_map: std.StringHashMap(i32),

    pub fn init(allocator: std.mem.Allocator, target: Target, tag_map: std.StringHashMap(i32)) Lowering {
        return .{
            .allocator = allocator,
            .target = target,
            .arg_count = 0,
            .tag_map = tag_map,
        };
    }

    fn emitMov(self: *Lowering, block: *LirBasicBlock, dest: LirRegister, src: LirOperand) !void {
        if (src == .reg) {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_rr),
                .dest = dest,
                .op1 = src,
            });
        } else if (src == .imm_int or src == .symbol) {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_ri),
                .dest = dest,
                .op1 = src,
            });
        } else if (src == .symbol_value) {
            // Load the 64-bit value stored at the external symbol (e.g. the
            // current arena pointer in orbit_global_arena).
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_rm_sym),
                .dest = dest,
                .op1 = .{ .symbol = src.symbol_value },
            });
        } else if (src == .imm_float) {
            // Materialize the IEEE-754 bit pattern in a GPR.
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_ri),
                .dest = dest,
                .op1 = .{ .imm_int = @bitCast(src.imm_float) },
            });
        } else if (src == .mem) {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_rm),
                .dest = dest,
                .op1 = src,
            });
        } else {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_ri),
                .dest = dest,
                .op1 = src,
            });
        }
    }

    /// Emits a call to a C runtime function following the target ABI.
    ///
    /// - `sret`: the function returns `OrbitResult` by value (24 bytes) via a
    ///   hidden first argument. A 32-byte scratch buffer is reserved at [rsp]
    ///   and its address is passed as argument 0; after the call `dest` is
    ///   loaded from the buffer's `.value` slot (offset 16), either directly
    ///   (`deref == false`, e.g. create) or as a 64-bit deref of it
    ///   (`deref == true`, e.g. get/pop).
    /// - `addr_of[i]`: operand i is passed as the *address* of the value, so
    ///   the value is materialized in R10, stored to an 8-byte slot pushed on
    ///   the stack, and RSP is passed (mirrors the C backend's `&r_N`).
    fn emitRuntimeCall(
        self: *Lowering,
        block: *LirBasicBlock,
        symbol: []const u8,
        sret: bool,
        args: []const LirOperand,
        addr_of: []const bool,
        dest: ?ValueId,
        deref: bool,
    ) !void {
        const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
        const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
        const r11_phys = LirRegister{ .id = @backingInt(RegisterId.r11), .is_physical = true };
        const rsp_phys = LirRegister{ .id = @backingInt(RegisterId.rsp), .is_physical = true };

        var arg_idx: usize = if (sret) 1 else 0;
        var pushed: usize = 0;

        for (args, addr_of) |arg, by_addr| {
            const arg_reg = LirRegister{ .id = @backingInt(arg_regs[arg_idx]), .is_physical = true };
            if (by_addr) {
                try self.emitMov(block, r10_phys, arg);
                // sub rsp, 8; mov [rsp], r10; mov arg_reg, rsp
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.sub_ri),
                    .dest = rsp_phys,
                    .op1 = .{ .imm_int = 8 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rsp_phys, .disp = 0 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rr),
                    .dest = arg_reg,
                    .op1 = .{ .reg = rsp_phys },
                });
                pushed += 1;
            } else {
                try self.emitMov(block, arg_reg, arg);
            }
            arg_idx += 1;
        }

        if (sret) {
            const sret_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
            // Reserve the result buffer and pass its address as hidden arg 0.
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.sub_ri),
                .dest = rsp_phys,
                .op1 = .{ .imm_int = 32 },
            });
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_rr),
                .dest = sret_reg,
                .op1 = .{ .reg = rsp_phys },
            });
        }

        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.call),
            .op1 = .{ .symbol = symbol },
        });

        if (sret) {
            if (dest) |d| {
                const dest_reg = mapReg(d);
                if (deref) {
                    // R11 = result.value (offset 16); dest = *R11
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rm),
                        .dest = r11_phys,
                        .op1 = .{ .mem = .{ .base = rsp_phys, .disp = 16 } },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rm),
                        .dest = dest_reg,
                        .op1 = .{ .mem = .{ .base = r11_phys, .disp = 0 } },
                    });
                } else {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rm),
                        .dest = dest_reg,
                        .op1 = .{ .mem = .{ .base = rsp_phys, .disp = 16 } },
                    });
                }
            }
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.add_ri),
                .dest = rsp_phys,
                .op1 = .{ .imm_int = 32 },
            });
        } else {
            if (dest) |d| {
                const dest_reg = mapReg(d);
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rr),
                    .dest = dest_reg,
                    .op1 = .{ .reg = rax_phys },
                });
            }
        }

        if (pushed > 0) {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.add_ri),
                .dest = rsp_phys,
                .op1 = .{ .imm_int = @intCast(pushed * 8) },
            });
        }
    }

    /// Emits `orbit_alloc(&orbit_global_arena value, size)`, leaving the result
    /// pointer in RAX. Uses the same global-arena load as the collections path.
    fn emitAllocFromArena(self: *Lowering, block: *LirBasicBlock, size: u32) !void {
        const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
        const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
        const arg2_reg = LirRegister{ .id = @backingInt(arg_regs[1]), .is_physical = true };
        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.mov_rm_sym),
            .dest = arg1_reg,
            .op1 = .{ .symbol = "orbit_global_arena" },
        });
        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.mov_ri),
            .dest = arg2_reg,
            .op1 = .{ .imm_int = size },
        });
        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.call),
            .op1 = .{ .symbol = "orbit_alloc" },
        });
    }

    fn xmmReg(id: u8) LirRegister {
        return .{ .id = id, .is_physical = true, .class = .xmm };
    }

    fn slotMem(reg_id: u32) LirOperand {
        const rbp_phys = LirRegister{ .id = @backingInt(RegisterId.rbp), .is_physical = true };
        return .{ .mem = .{ .base = rbp_phys, .disp = -@as(i32, @intCast((reg_id + 1) * 8)) } };
    }

    fn operandIsFloat(op: LirOperand, mir_func: *const MirFunction) bool {
        if (op == .imm_float) return true;
        if (op == .reg and op.reg.id < mir_func.val_types.items.len) {
            return mir_func.val_types.items[op.reg.id] == .float;
        }
        return false;
    }

    fn operandIsString(op: LirOperand, mir_func: *const MirFunction) bool {
        if (op == .symbol) return true;
        if (op == .reg and op.reg.id < mir_func.val_types.items.len) {
            return mir_func.val_types.items[op.reg.id] == .string;
        }
        return false;
    }

    /// Emit a call to the runtime stringifier for a non-string operand
    /// (orbit_int_to_string / orbit_bool_to_string / orbit_float_to_string).
    /// The resulting string is left in RAX.
    fn emitToString(self: *Lowering, block: *LirBasicBlock, op: LirOperand, mir_func: *const MirFunction) !void {
        if (operandIsFloat(op, mir_func)) {
            try self.emitFloatLoadXmm(block, Lowering.xmmReg(0), op);
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.call),
                .op1 = .{ .symbol = "orbit_float_to_string" },
            });
        } else {
            const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
            const arg0_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
            try self.emitMov(block, arg0_reg, op);
            var is_bool = false;
            if (op == .reg and op.reg.id < mir_func.val_types.items.len) {
                is_bool = mir_func.val_types.items[op.reg.id] == .bool;
            }
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.call),
                .op1 = .{ .symbol = if (is_bool) "orbit_bool_to_string" else "orbit_int_to_string" },
            });
        }
    }

    /// Load a float-typed value into a physical XMM register. Sources may be a
    /// virtual register (loaded from its stack slot) or an immediate (bit-pattern
    /// materialized through RAX and movq).
    fn emitFloatLoadXmm(self: *Lowering, block: *LirBasicBlock, xmm: LirRegister, src: LirOperand) !void {
        if (src == .reg) {
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.movsd_rm),
                .dest = xmm,
                .op1 = slotMem(src.reg.id),
            });
        } else if (src == .imm_float) {
            const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.mov_ri),
                .dest = rax_phys,
                .op1 = .{ .imm_int = @bitCast(src.imm_float) },
            });
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.movq_rr),
                .dest = xmm,
                .op1 = .{ .reg = rax_phys },
            });
        } else if (src == .imm_int) {
            const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
            try self.emitMov(block, rax_phys, src);
            try block.instructions.append(self.allocator, .{
                .opcode = @backingInt(X86Opcode.movq_rr),
                .dest = xmm,
                .op1 = .{ .reg = rax_phys },
            });
        } else {
            unreachable;
        }
    }

    /// Store a float constant's bit pattern directly into a virtual register slot.
    fn emitFloatConstToSlot(self: *Lowering, block: *LirBasicBlock, dest_reg_id: u32, value: f64) !void {
        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.mov_ri),
            .dest = rax_phys,
            .op1 = .{ .imm_int = @bitCast(value) },
        });
        try block.instructions.append(self.allocator, .{
            .opcode = @backingInt(X86Opcode.mov_mr),
            .op1 = slotMem(dest_reg_id),
            .op2 = .{ .reg = rax_phys },
        });
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
                    const param_type = mir_func.param_types[param_idx];
                    if (param_type == .float) {
                        // Float parameters arrive in XMM registers (one per ABI
                        // position); write the bits directly into the stack slot.
                        const xmm = Lowering.xmmReg(@intCast(param_idx));
                        try entry_block.instructions.insert(self.allocator, param_idx, .{
                            .opcode = @backingInt(X86Opcode.movsd_mr),
                            .op1 = Lowering.slotMem(@intCast(param_reg_id)),
                            .op2 = .{ .reg = xmm },
                        });
                    } else {
                        const src_phys_reg = LirRegister{ .id = @backingInt(abi_regs[param_idx]), .is_physical = true };
                        // Prepend mov dest_reg, src_phys_reg
                        try entry_block.instructions.insert(self.allocator, param_idx, .{
                            .opcode = @backingInt(X86Opcode.mov_rr),
                            .dest = dest_reg,
                            .op1 = .{ .reg = src_phys_reg },
                        });
                    }
                } else {
                    // Parameter passed on stack.
                    // The stack parameters are located at [RBP + 16 + (param_idx - abi_regs.len)*8]
                    const disp: i32 = @intCast(16 + (param_idx - abi_regs.len) * 8);

                    const rbp_phys = LirRegister{ .id = @backingInt(RegisterId.rbp), .is_physical = true };
                    // Prepend mov dest_reg, [RBP + disp]
                    try entry_block.instructions.insert(self.allocator, param_idx, .{
                        .opcode = @backingInt(X86Opcode.mov_rm),
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
        return switch (op) {
            .none => .none,
            .reg => |r| .{ .reg = mapReg(r) },
            .imm_int => |v| .{ .imm_int = v },
            .imm_float => |v| .{ .imm_float = v },
            .imm_bool => |v| .{ .imm_int = if (v) 1 else 0 },
            .imm_str => |v| blk: {
                // Tag constants ("Foo_TAG_Bar") resolve to their variant index;
                // every other string literal materializes as a symbol address.
                if (self.tag_map.get(v)) |idx| {
                    break :blk .{ .imm_int = idx };
                }
                break :blk .{ .symbol = v };
            },
            .block => |b| .{ .label = b },
        };
    }

    fn lowerInstruction(self: *Lowering, mir_instr: MirInstruction, block: *LirBasicBlock, mir_func: *const MirFunction) !void {
        const op1_lir = self.mapOperand(mir_instr.op1);
        const op2_lir = self.mapOperand(mir_instr.op2);

        switch (mir_instr.opcode) {
            .nop => {},
            .load_field => {
                // dest = *(i64*)(obj + offset)
                const dest = mapReg(mir_instr.dest.?);
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try self.emitMov(block, r10_phys, op1_lir);
                const offset: i32 = if (op2_lir == .imm_int) @intCast(op2_lir.imm_int) else 0;
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = dest,
                    .op1 = .{ .mem = .{ .base = r10_phys, .disp = offset } },
                });
            },
            .store_field => {
                // *(i64*)(obj + offset) = value
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try self.emitMov(block, r10_phys, op1_lir);
                const offset: i32 = if (op2_lir == .imm_int) @intCast(op2_lir.imm_int) else 0;
                const op3_lir = self.mapOperand(mir_instr.op3);
                if (op3_lir == .reg) {
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_mr),
                        .op1 = .{ .mem = .{ .base = r10_phys, .disp = offset } },
                        .op2 = op3_lir,
                    });
                } else {
                    // Materialize non-register values in R11 (self-contained
                    // sequence; the register allocator only touches R11 when
                    // loading *virtual* source registers).
                    const r11_phys = LirRegister{ .id = @backingInt(RegisterId.r11), .is_physical = true };
                    try self.emitMov(block, r11_phys, op3_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_mr),
                        .op1 = .{ .mem = .{ .base = r10_phys, .disp = offset } },
                        .op2 = .{ .reg = r11_phys },
                    });
                }
            },
            .list_create => try self.emitRuntimeCall(block, "orbit_list_create", true, &.{ .{ .symbol_value = "orbit_global_arena" }, op1_lir, op2_lir }, &.{ false, false, false }, mir_instr.dest, false),
            .list_push => try self.emitRuntimeCall(block, "orbit_list_push", true, &.{ op1_lir, op2_lir }, &.{ false, true }, null, false),
            .list_pop => try self.emitRuntimeCall(block, "orbit_list_pop", true, &.{op1_lir}, &.{false}, mir_instr.dest, true),
            .list_get => try self.emitRuntimeCall(block, "orbit_list_get_native", true, &.{ op1_lir, op2_lir }, &.{ false, false }, mir_instr.dest, true),
            .list_set => try self.emitRuntimeCall(block, "orbit_list_set", true, &.{ op1_lir, op2_lir, self.mapOperand(mir_instr.op3) }, &.{ false, false, true }, null, false),
            .list_len => try self.emitRuntimeCall(block, "orbit_list_len_native", false, &.{op1_lir}, &.{false}, mir_instr.dest, false),
            .map_create => try self.emitRuntimeCall(block, "orbit_map_create", true, &.{ .{ .symbol_value = "orbit_global_arena" }, op1_lir }, &.{ false, false }, mir_instr.dest, false),
            .map_set => try self.emitRuntimeCall(block, "orbit_map_set", true, &.{ op1_lir, op2_lir, self.mapOperand(mir_instr.op3) }, &.{ false, false, true }, null, false),
            .map_get => try self.emitRuntimeCall(block, "orbit_map_get_native", true, &.{ op1_lir, op2_lir }, &.{ false, false }, mir_instr.dest, true),
            .map_has => try self.emitRuntimeCall(block, "orbit_map_has_native", false, &.{ op1_lir, op2_lir }, &.{ false, false }, mir_instr.dest, false),
            .result_ok => {
                // OrbitResult { ok=true@0, error_code=0@4, error_msg=NULL@8, value@16 }
                try self.emitAllocFromArena(block, 24);
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                const r11_phys = LirRegister{ .id = @backingInt(RegisterId.r11), .is_physical = true };
                // ok=true + error_code=0 in one 64-bit store at [rax+0].
                try self.emitMov(block, r11_phys, op1_lir); // value
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_ri),
                    .dest = r10_phys,
                    .op1 = .{ .imm_int = 1 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 0 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_ri),
                    .dest = r10_phys,
                    .op1 = .{ .imm_int = 0 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 8 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 16 } },
                    .op2 = .{ .reg = r11_phys },
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rr),
                    .dest = dest,
                    .op1 = .{ .reg = rax_phys },
                });
            },
            .result_err => {
                // OrbitResult { ok=false@0, error_code=op1@4, error_msg=op2@8, value=NULL@16 }
                try self.emitAllocFromArena(block, 24);
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                const r11_phys = LirRegister{ .id = @backingInt(RegisterId.r11), .is_physical = true };
                try self.emitMov(block, r11_phys, op2_lir); // msg
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_ri),
                    .dest = r10_phys,
                    .op1 = .{ .imm_int = 0 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 0 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try self.emitMov(block, r10_phys, op1_lir); // code
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr32),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 4 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 8 } },
                    .op2 = .{ .reg = r11_phys },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_ri),
                    .dest = r10_phys,
                    .op1 = .{ .imm_int = 0 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 16 } },
                    .op2 = .{ .reg = r10_phys },
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rr),
                    .dest = dest,
                    .op1 = .{ .reg = rax_phys },
                });
            },
            .result_is_ok => {
                // Load the result pointer from its stack slot into a physical
                // scratch (the regalloc only resolves virtual regs in .reg
                // operands, not mem bases), then read the ok byte.
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = r10_phys,
                    .op1 = slotMem(mir_instr.op1.reg),
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.movzx_rm),
                    .dest = dest,
                    .op1 = .{ .mem = .{ .base = r10_phys, .disp = 0 } },
                });
            },
            .result_unwrap => {
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = r10_phys,
                    .op1 = slotMem(mir_instr.op1.reg),
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = dest,
                    .op1 = .{ .mem = .{ .base = r10_phys, .disp = 16 } },
                });
            },
            .union_create => {
                // OrbitUnion { int tag@0; union { void* data; } data@8; } (16 bytes).
                try self.emitAllocFromArena(block, 16);
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                const r11_phys = LirRegister{ .id = @backingInt(RegisterId.r11), .is_physical = true };
                try self.emitMov(block, r10_phys, op1_lir); // tag (resolved to index)
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr32),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 0 } },
                    .op2 = .{ .reg = r10_phys },
                });
                try self.emitMov(block, r11_phys, op2_lir); // data
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rax_phys, .disp = 8 } },
                    .op2 = .{ .reg = r11_phys },
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rr),
                    .dest = dest,
                    .op1 = .{ .reg = rax_phys },
                });
            },
            .union_get_tag => {
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = r10_phys,
                    .op1 = slotMem(mir_instr.op1.reg),
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm32),
                    .dest = dest,
                    .op1 = .{ .mem = .{ .base = r10_phys, .disp = 0 } },
                });
            },
            .union_get_data => {
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = r10_phys,
                    .op1 = slotMem(mir_instr.op1.reg),
                });
                const dest = mapReg(mir_instr.dest.?);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm),
                    .dest = dest,
                    .op1 = .{ .mem = .{ .base = r10_phys, .disp = 8 } },
                });
            },
            .copy => {
                const dest = mapReg(mir_instr.dest.?);
                const dest_type = mir_func.val_types.items[mir_instr.dest.?];
                if (dest_type == .float) {
                    // Float values live in stack slots; materialize directly there
                    // so the register allocator never touches a float via GPRs.
                    if (op1_lir == .imm_float) {
                        try self.emitFloatConstToSlot(block, mir_instr.dest.?, op1_lir.imm_float);
                    } else if (op1_lir == .imm_int) {
                        try self.emitFloatConstToSlot(block, mir_instr.dest.?, @floatFromInt(op1_lir.imm_int));
                    } else if (op1_lir == .reg) {
                        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.mov_rm),
                            .dest = rax_phys,
                            .op1 = slotMem(op1_lir.reg.id),
                        });
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.mov_mr),
                            .op1 = slotMem(mir_instr.dest.?),
                            .op2 = .{ .reg = rax_phys },
                        });
                    }
                } else {
                    try self.emitMov(block, dest, op1_lir);
                }
            },
            .add => {
                const dest = mapReg(mir_instr.dest.?);
                const dest_type = mir_func.val_types.items[mir_instr.dest.?];
                if (dest_type == .float) {
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.addsd_rr),
                        .dest = xmm0,
                        .op1 = .{ .reg = xmm1 },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movsd_mr),
                        .op1 = slotMem(mir_instr.dest.?),
                        .op2 = .{ .reg = xmm0 },
                    });
                } else if (dest_type == .string) {
                    const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                    const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                    const arg2_reg = LirRegister{ .id = @backingInt(arg_regs[1]), .is_physical = true };
                    // Non-string operands must be stringified first, mirroring the
                    // C backend (orbit_int_to_string / orbit_bool_to_string /
                    // orbit_float_to_string). Convert operand2 before operand1 so
                    // its to_string call can safely use arg1 as scratch.
                    var op1_conv = op1_lir;
                    var op2_conv = op2_lir;
                    if (!operandIsString(op2_lir, mir_func)) {
                        try self.emitToString(block, op2_lir, mir_func);
                        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                        try self.emitMov(block, arg2_reg, .{ .reg = rax_phys });
                        op2_conv = .{ .reg = arg2_reg };
                    }
                    if (!operandIsString(op1_lir, mir_func)) {
                        try self.emitToString(block, op1_lir, mir_func);
                        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                        try self.emitMov(block, arg1_reg, .{ .reg = rax_phys });
                        op1_conv = .{ .reg = arg1_reg };
                    }
                    try self.emitMov(block, arg1_reg, op1_conv);
                    try self.emitMov(block, arg2_reg, op2_conv);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.call),
                        .op1 = .{ .symbol = "orbit_string_concat" },
                    });
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                } else {
                    if (op2_lir == .reg and op2_lir.reg.id == dest.id) {
                        const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                        try self.emitMov(block, r10_phys, op1_lir);
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.add_rr),
                            .dest = dest,
                            .op1 = .{ .reg = r10_phys },
                        });
                    } else {
                        try self.emitMov(block, dest, op1_lir);
                        if (op2_lir == .reg) {
                            try block.instructions.append(self.allocator, .{
                                .opcode = @backingInt(X86Opcode.add_rr),
                                .dest = dest,
                                .op1 = op2_lir,
                            });
                        } else {
                            const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                            try self.emitMov(block, r10_phys, op2_lir);
                            try block.instructions.append(self.allocator, .{
                                .opcode = @backingInt(X86Opcode.add_rr),
                                .dest = dest,
                                .op1 = .{ .reg = r10_phys },
                            });
                        }
                    }
                }
            },
            .sub => {
                const dest = mapReg(mir_instr.dest.?);
                if (mir_func.val_types.items[mir_instr.dest.?] == .float) {
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.subsd_rr),
                        .dest = xmm0,
                        .op1 = .{ .reg = xmm1 },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movsd_mr),
                        .op1 = slotMem(mir_instr.dest.?),
                        .op2 = .{ .reg = xmm0 },
                    });
                } else if (op2_lir == .reg and op2_lir.reg.id == dest.id) {
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op1_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.sub_rr),
                        .dest = r10_phys,
                        .op1 = op2_lir,
                    });
                    try self.emitMov(block, dest, .{ .reg = r10_phys });
                } else {
                    try self.emitMov(block, dest, op1_lir);
                    if (op2_lir == .reg) {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.sub_rr),
                            .dest = dest,
                            .op1 = op2_lir,
                        });
                    } else {
                        const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                        try self.emitMov(block, r10_phys, op2_lir);
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.sub_rr),
                            .dest = dest,
                            .op1 = .{ .reg = r10_phys },
                        });
                    }
                }
            },
            .mul => {
                const dest = mapReg(mir_instr.dest.?);
                if (mir_func.val_types.items[mir_instr.dest.?] == .float) {
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mulsd_rr),
                        .dest = xmm0,
                        .op1 = .{ .reg = xmm1 },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movsd_mr),
                        .op1 = slotMem(mir_instr.dest.?),
                        .op2 = .{ .reg = xmm0 },
                    });
                } else if (op2_lir == .reg and op2_lir.reg.id == dest.id) {
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op1_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.imul_rr),
                        .dest = dest,
                        .op1 = .{ .reg = r10_phys },
                    });
                } else {
                    try self.emitMov(block, dest, op1_lir);
                    if (op2_lir == .reg) {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.imul_rr),
                            .dest = dest,
                            .op1 = op2_lir,
                        });
                    } else {
                        const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                        try self.emitMov(block, r10_phys, op2_lir);
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.imul_rr),
                            .dest = dest,
                            .op1 = .{ .reg = r10_phys },
                        });
                    }
                }
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const dest = mapReg(mir_instr.dest.?);

                if (operandIsFloat(op1_lir, mir_func) or operandIsFloat(op2_lir, mir_func)) {
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    // ucomisd sets: CF for below, ZF for equal. NaN compares as
                    // unordered (CF=ZF=PF=1), so eq/ne on NaN yield 0/1.
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.ucomisd_rr),
                        .dest = xmm0,
                        .op1 = .{ .reg = xmm1 },
                    });
                    const set_opcode = switch (mir_instr.opcode) {
                        .eq => X86Opcode.sete_r,
                        .ne => X86Opcode.setne_r,
                        .lt => X86Opcode.setb_r,
                        .le => X86Opcode.setbe_r,
                        .gt => X86Opcode.seta_r,
                        .ge => X86Opcode.setae_r,
                        else => unreachable,
                    };
                    // setcc writes a byte; movzx below zero-extends it, so the
                    // destination is never written through a flag-clobbering
                    // mov-0->xor before the condition is read.
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(set_opcode),
                        .dest = dest,
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movzx_rr),
                        .dest = dest,
                        .op1 = .{ .reg = dest },
                    });
                    return;
                }

                var rhs_val = op2_lir;
                if (op2_lir == .symbol) {
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    rhs_val = .{ .reg = r10_phys };
                }

                var is_string_cmp = false;
                if (mir_instr.opcode == .eq or mir_instr.opcode == .ne) {
                    if (mir_instr.op1 == .imm_str or mir_instr.op2 == .imm_str) {
                        is_string_cmp = true;
                    } else if (mir_instr.op1 == .reg and mir_instr.op1.reg < mir_func.val_types.items.len) {
                        if (mir_func.val_types.items[mir_instr.op1.reg] == .string) {
                            is_string_cmp = true;
                        }
                    }
                }

                if (is_string_cmp) {
                    const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                    const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                    const arg2_reg = LirRegister{ .id = @backingInt(arg_regs[1]), .is_physical = true };
                    if (op1_lir == .reg and rhs_val == .reg and op1_lir.reg.id == arg2_reg.id and rhs_val.reg.id == arg1_reg.id) {
                        const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
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
                        .opcode = @backingInt(X86Opcode.call),
                        .op1 = .{ .symbol = "strcmp" },
                    });
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.cmp_ri),
                        .dest = rax_phys,
                        .op1 = .{ .imm_int = 0 },
                    });
                    const set_opcode = switch (mir_instr.opcode) {
                        .eq => X86Opcode.sete_r,
                        .ne => X86Opcode.setne_r,
                        else => unreachable,
                    };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(set_opcode),
                        .dest = dest,
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movzx_rr),
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
                            .opcode = @backingInt(X86Opcode.cmp_ri),
                            .dest = lhs_reg,
                            .op1 = rhs_val,
                        });
                    } else {
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.cmp_rr),
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

                    // setcc writes a byte; movzx below zero-extends it. A prior
                    // mov-0 would peephole to xor and clobber the flags.
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(set_opcode),
                        .dest = dest,
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movzx_rr),
                        .dest = dest,
                        .op1 = .{ .reg = dest },
                    });
                }
            },
            .jmp => {
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.jmp),
                    .op1 = op1_lir,
                });
            },
            .jmp_if => {
                // MIR jmp_if coming from IR jump_if_false: cmp cond, 0 -> je target (jump if false/zero)
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.cmp_ri),
                    .dest = op1_lir.reg,
                    .op1 = .{ .imm_int = 0 },
                });
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.je),
                    .op1 = op2_lir,
                });
            },
            .arg => {
                const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                const is_float_arg = operandIsFloat(op1_lir, mir_func);
                const float_arg_regs: usize = if (self.target.abi == .windows_x64) 4 else 8;
                // Hidden sret calls reserve ABI position 0 for the result pointer.
                const pos = self.arg_count + (if (self.sret_pending) @as(usize, 1) else 0);
                if (is_float_arg and pos < float_arg_regs) {
                    // Floating-point arguments are passed in XMM registers, one
                    // per ABI position (XMM0 for position 0, XMM1 for position 1...).
                    const xmm = Lowering.xmmReg(@intCast(pos));
                    try self.emitFloatLoadXmm(block, xmm, op1_lir);
                } else if (pos < arg_regs.len) {
                    const arg_reg_id = arg_regs[pos];
                    const phys_reg = LirRegister{
                        .id = @backingInt(arg_reg_id),
                        .is_physical = true,
                    };
                    try self.emitMov(block, phys_reg, op1_lir);
                } else {
                    // Stack-passed argument: sub rsp, 8  then  mov [rsp], src.
                    // We use R10 as a scratch to materialise non-register sources.
                    const rsp_phys = LirRegister{ .id = @backingInt(RegisterId.rsp), .is_physical = true };
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };

                    // sub rsp, 8
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.sub_ri),
                        .dest = rsp_phys,
                        .op1 = .{ .imm_int = 8 },
                    });

                    // Materialize the value into R10 if it is not already a register.
                    const src_reg: LirRegister = if (op1_lir == .reg) op1_lir.reg else blk: {
                        try self.emitMov(block, r10_phys, op1_lir);
                        break :blk r10_phys;
                    };

                    // mov [rsp], src_reg
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_mr),
                        .op1 = .{ .mem = .{ .base = rsp_phys, .disp = 0 } },
                        .op2 = .{ .reg = src_reg },
                    });
                }
                self.arg_count += 1;
            },
            .ret => {
                if (mir_instr.op1 != .none) {
                    if (operandIsFloat(op1_lir, mir_func)) {
                        // Floating-point values return in XMM0.
                        try self.emitFloatLoadXmm(block, Lowering.xmmReg(0), op1_lir);
                    } else {
                        // RAX is the standard return register on both Windows and SysV ABI.
                        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                        try self.emitMov(block, rax_phys, op1_lir);
                    }
                }
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.ret),
                });
            },
            .call => {
                // Reset argument count for the next call sequence
                self.arg_count = 0;
                if (self.sret_pending) {
                    // Hidden sret call: pass the arena-allocated OrbitResult buffer
                    // (held in dest) as argument 0 before the explicit arguments.
                    if (mir_instr.dest) |d| {
                        const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                        const arg0_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                        try self.emitMov(block, arg0_reg, .{ .reg = mapReg(d) });
                    }
                    self.sret_pending = false;
                }

                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = op1_lir,
                });

                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    if (d < mir_func.val_types.items.len and mir_func.val_types.items[d] == .float) {
                        // Floating-point results return in XMM0.
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.movsd_mr),
                            .op1 = slotMem(d),
                            .op2 = .{ .reg = Lowering.xmmReg(0) },
                        });
                    } else {
                        const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                        try block.instructions.append(self.allocator, .{
                            .opcode = @backingInt(X86Opcode.mov_rr),
                            .dest = dest,
                            .op1 = .{ .reg = rax_phys },
                        });
                    }
                }
            },
            .div, .mod => {
                const dest = mapReg(mir_instr.dest.?);
                const dest_is_float = mir_instr.dest.? < mir_func.val_types.items.len and mir_func.val_types.items[mir_instr.dest.?] == .float;
                const op_is_float = operandIsFloat(op1_lir, mir_func) or operandIsFloat(op2_lir, mir_func);
                if ((dest_is_float or op_is_float) and mir_instr.opcode == .div) {
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.divsd_rr),
                        .dest = xmm0,
                        .op1 = .{ .reg = xmm1 },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movsd_mr),
                        .op1 = slotMem(mir_instr.dest.?),
                        .op2 = .{ .reg = xmm0 },
                    });
                } else if (op_is_float and mir_instr.opcode == .mod) {
                    // fmod(double, double) -> XMM0/XMM1 args, XMM0 result.
                    const xmm0 = Lowering.xmmReg(0);
                    const xmm1 = Lowering.xmmReg(1);
                    try self.emitFloatLoadXmm(block, xmm0, op1_lir);
                    try self.emitFloatLoadXmm(block, xmm1, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.call),
                        .op1 = .{ .symbol = "fmod" },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.movsd_mr),
                        .op1 = slotMem(mir_instr.dest.?),
                        .op2 = .{ .reg = xmm0 },
                    });
                } else {
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                const rdx_phys = LirRegister{ .id = @backingInt(RegisterId.rdx), .is_physical = true };
                const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };

                // Dividend -> RAX.
                try self.emitMov(block, rax_phys, op1_lir);
                // Divisor -> R10 (never an implicit operand of idiv).
                try self.emitMov(block, r10_phys, op2_lir);
                // Sign-extend RAX into RDX:RAX.
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.cqo),
                });
                // idiv r10 -> quotient in RAX, remainder in RDX.
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.idiv_r),
                    .op1 = .{ .reg = r10_phys },
                });
                const result_reg = if (mir_instr.opcode == .div) rax_phys else rdx_phys;
                try self.emitMov(block, dest, .{ .reg = result_reg });
                }
            },
            .neg, .not_op => {
                const dest = mapReg(mir_instr.dest.?);
                if (mir_instr.opcode == .neg and operandIsFloat(op1_lir, mir_func)) {
                    // IEEE 754 negation flips the sign bit: xor 0x8000000000000000.
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, rax_phys, op1_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_ri),
                        .dest = r10_phys,
                        .op1 = .{ .imm_int = std.math.minInt(i64) },
                    });
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.xor_rr),
                        .dest = rax_phys,
                        .op1 = .{ .reg = r10_phys },
                    });
                    try self.emitMov(block, dest, .{ .reg = rax_phys });
                } else {
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                try self.emitMov(block, rax_phys, op1_lir);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(if (mir_instr.opcode == .neg) X86Opcode.neg_r else X86Opcode.not_r),
                    .dest = rax_phys,
                });
                try self.emitMov(block, dest, .{ .reg = rax_phys });
                }
            },
            .shl, .shr => {
                const dest = mapReg(mir_instr.dest.?);
                const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                const rcx_phys = LirRegister{ .id = @backingInt(RegisterId.rcx), .is_physical = true };
                // Value -> RAX, shift count -> CL (RCX).
                try self.emitMov(block, rax_phys, op1_lir);
                try self.emitMov(block, rcx_phys, op2_lir);
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(if (mir_instr.opcode == .shl) X86Opcode.shl_r else X86Opcode.shr_r),
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
                        .opcode = @backingInt(rr_op),
                        .dest = dest,
                        .op1 = op2_lir,
                    });
                } else {
                    // No reg,imm form for these; materialize the immediate in R10.
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(rr_op),
                        .dest = dest,
                        .op1 = .{ .reg = r10_phys },
                    });
                }
            },
            .alloc_stack => {
                // Stack allocation is handled by frame size computation during regalloc.
                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rbp_phys = LirRegister{ .id = @backingInt(RegisterId.rbp), .is_physical = true };
                    // For stack allocation, load address [rbp - 16] into dest
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rbp_phys },
                    });
                }
            },
            .load_stack => {
                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rbp_phys = LirRegister{ .id = @backingInt(RegisterId.rbp), .is_physical = true };
                    const disp: i32 = if (op1_lir == .imm_int) -@as(i32, @intCast(op1_lir.imm_int)) else -8;
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rm),
                        .dest = dest,
                        .op1 = .{ .mem = .{ .base = rbp_phys, .disp = disp } },
                    });
                }
            },
            .store_stack => {
                const rbp_phys = LirRegister{ .id = @backingInt(RegisterId.rbp), .is_physical = true };
                const disp: i32 = if (op1_lir == .imm_int) -@as(i32, @intCast(op1_lir.imm_int)) else -8;
                const src_reg = if (op2_lir == .reg) op2_lir.reg else blk: {
                    const r10_phys = LirRegister{ .id = @backingInt(RegisterId.r10), .is_physical = true };
                    try self.emitMov(block, r10_phys, op2_lir);
                    break :blk r10_phys;
                };
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_mr),
                    .op1 = .{ .mem = .{ .base = rbp_phys, .disp = disp } },
                    .op2 = .{ .reg = src_reg },
                });
            },
            .arena_alloc => {
                const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                const arg2_reg = LirRegister{ .id = @backingInt(arg_regs[1]), .is_physical = true };
                // orbit_alloc(OrbitArena* arena, size_t bytes); the native stub
                // owns the global arena, mirroring the C backend's arena-alloc.
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.mov_rm_sym),
                    .dest = arg1_reg,
                    .op1 = .{ .symbol = "orbit_global_arena" },
                });
                try self.emitMov(block, arg2_reg, op1_lir);

                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = .{ .symbol = "orbit_alloc" },
                });

                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                }
            },
            .sret_alloc => {
                // Arena-allocate the 24-byte OrbitResult buffer the callee writes
                // through its hidden sret pointer; the pointer lands in dest.
                try self.emitAllocFromArena(block, 24);
                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                }
                self.sret_pending = true;
            },
            .kynx_lease_check => {
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = .{ .symbol = "kynx_check_lease" },
                });
            },
            .kynx_lease_end => {
                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = .{ .symbol = "kynx_end_lease" },
                });
            },
            .db_query => {
                const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                try self.emitMov(block, arg1_reg, op1_lir);

                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = .{ .symbol = "orbit_db_query" },
                });

                if (mir_instr.dest) |d| {
                    const dest = mapReg(d);
                    const rax_phys = LirRegister{ .id = @backingInt(RegisterId.rax), .is_physical = true };
                    try block.instructions.append(self.allocator, .{
                        .opcode = @backingInt(X86Opcode.mov_rr),
                        .dest = dest,
                        .op1 = .{ .reg = rax_phys },
                    });
                }
            },
            .http_write => {
                const arg_regs = if (self.target.abi == .windows_x64) &reg_mod.windows_args else &reg_mod.sysv_args;
                const arg1_reg = LirRegister{ .id = @backingInt(arg_regs[0]), .is_physical = true };
                try self.emitMov(block, arg1_reg, op1_lir);

                try block.instructions.append(self.allocator, .{
                    .opcode = @backingInt(X86Opcode.call),
                    .op1 = .{ .symbol = "orbit_http_send" },
                });
            },
            else => {},
        }
    }
};
