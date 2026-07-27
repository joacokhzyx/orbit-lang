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

    /// Linear-scan register allocator (Poletto & Sarkar 1999).
    ///
    /// 1. Flatten all LIR instructions into a linear sequence and assign each
    ///    one a unique program-point index.
    /// 2. Compute live intervals [start, end) for every virtual register.
    /// 3. Walk the intervals in start order, maintaining an "active" set of
    ///    intervals that currently hold a physical register.
    /// 4. Expire (free) intervals whose end precedes the current start.
    /// 5. If a physical register is available, assign it.  Otherwise spill the
    ///    interval with the furthest end (or the current interval if it ends later).
    /// 6. Emit the final instructions replacing every virtual register reference
    ///    with its assigned physical register, inserting loads/stores for spills.
    fn allocateLinear(self: *RegisterAllocator, func: *const LirFunction) !LirFunction {
        // Caller-saved (volatile) registers we may freely use as scratch.
        // We exclude RAX (used for return values), RCX/RDX/R8/R9 (ABI arg regs),
        // RBP/RSP (frame pointers), and R10/R11 (reserved as scratch by lowering).
        const pool = [_]RegisterId{ .rbx, .rsi, .rdi, .r12, .r13, .r14, .r15 };

        // ── 1. Flatten instructions ──────────────────────────────────────────
        // For each program point, record its block index and instruction index.
        const Point = struct { block_idx: usize, instr_idx: usize };
        var points = std.ArrayListUnmanaged(Point).empty;
        defer points.deinit(self.allocator);

        for (func.blocks.items, 0..) |*blk, bi| {
            for (0..blk.instructions.items.len) |ii| {
                try points.append(self.allocator, .{ .block_idx = bi, .instr_idx = ii });
            }
        }

        // ── 2. Compute live intervals ────────────────────────────────────────
        // Determine the maximum virtual register id.
        var max_virt: u32 = 0;
        for (func.blocks.items) |*blk| {
            for (blk.instructions.items) |instr| {
                if (instr.dest) |d| if (!d.is_physical and d.id > max_virt) { max_virt = d.id; };
                inline for (.{ instr.op1, instr.op2, instr.op3 }) |op| {
                    if (op == .reg and !op.reg.is_physical and op.reg.id > max_virt) {
                        max_virt = op.reg.id;
                    }
                }
            }
        }

        const Interval = struct { start: usize = 0, end: usize = 0, live: bool = false };
        var intervals = try self.allocator.alloc(Interval, max_virt + 1);
        defer self.allocator.free(intervals);
        for (intervals) |*iv| iv.* = .{};

        // Walk all points and update live ranges.
        for (points.items, 0..) |pt, pp| {
            const instr = func.blocks.items[pt.block_idx].instructions.items[pt.instr_idx];

            if (instr.dest) |d| {
                if (!d.is_physical) {
                    const iv = &intervals[d.id];
                    if (!iv.live) { iv.start = pp; iv.live = true; }
                    if (pp > iv.end) iv.end = pp;
                }
            }
            inline for (.{ instr.op1, instr.op2, instr.op3 }) |op| {
                if (op == .reg and !op.reg.is_physical) {
                    const iv = &intervals[op.reg.id];
                    if (!iv.live) { iv.start = pp; iv.live = true; }
                    if (pp > iv.end) iv.end = pp;
                }
            }
        }

        // ── 3. Linear scan ──────────────────────────────────────────────────
        // reg_map[virt_id] = physical reg id, or null if spilled.
        var reg_map = try self.allocator.alloc(?u32, max_virt + 1);
        defer self.allocator.free(reg_map);
        for (reg_map) |*r| r.* = null;

        // spill_slot[virt_id] = stack slot index (1-based offset from base), or 0 = not spilled.
        var spill_slot = try self.allocator.alloc(u32, max_virt + 1);
        defer self.allocator.free(spill_slot);
        for (spill_slot) |*s| s.* = 0;

        var next_spill_slot: u32 = 1;
        var phys_free: [pool.len]bool = undefined;
        for (&phys_free) |*f| f.* = true; // all registers start free
        // active[pool_idx] = (virt_id, end) of the interval currently using pool[pool_idx]
        const ActiveEntry = struct { virt_id: u32, end: usize };
        var active: [pool.len]?ActiveEntry = undefined;
        for (&active) |*a| a.* = null;

        // Build a sorted order (by interval start).
        const sorted_ids = try self.allocator.alloc(u32, max_virt + 1);
        defer self.allocator.free(sorted_ids);
        for (sorted_ids, 0..) |*id, i| id.* = @intCast(i);
        std.sort.pdq(u32, sorted_ids, intervals, struct {
            fn lessThan(ivs: []Interval, a: u32, b: u32) bool {
                return ivs[a].start < ivs[b].start;
            }
        }.lessThan);

        for (sorted_ids) |vid| {
            if (!intervals[vid].live) continue;
            const cur_start = intervals[vid].start;
            const cur_end   = intervals[vid].end;

            // Expire intervals that ended before cur_start.
            for (&active, 0..) |*ae, pi| {
                if (ae.* == null) continue;
                if (ae.*.?.end < cur_start) {
                    phys_free[pi] = true;
                    ae.* = null;
                }
            }

            // Find a free physical register.
            var assigned: ?usize = null;
            for (phys_free, 0..) |free, pi| {
                if (free) { assigned = pi; break; }
            }

            if (assigned) |pi| {
                reg_map[vid] = @intFromEnum(pool[pi]);
                phys_free[pi] = false;
                active[pi] = .{ .virt_id = vid, .end = cur_end };
            } else {
                // Spill: find the active interval with the furthest end.
                var spill_pi: usize = 0;
                var spill_end: usize = 0;
                for (active, 0..) |ae, pi| {
                    if (ae) |a| {
                        if (a.end > spill_end) { spill_end = a.end; spill_pi = pi; }
                    }
                }
                if (spill_end > cur_end) {
                    // Spill the active occupant; give its physical register to current.
                    const victim = active[spill_pi].?;
                    reg_map[vid] = @intFromEnum(pool[spill_pi]);
                    reg_map[victim.virt_id] = null;
                    spill_slot[victim.virt_id] = next_spill_slot;
                    next_spill_slot += 1;
                    active[spill_pi] = .{ .virt_id = vid, .end = cur_end };
                } else {
                    // Spill current interval.
                    spill_slot[vid] = next_spill_slot;
                    next_spill_slot += 1;
                }
            }
        }

        // If no intervals were live at all, fall back to stack allocator.
        if (max_virt == 0 and !intervals[0].live) {
            return self.allocateStack(func);
        }

        // ── 4. Rewrite instructions ──────────────────────────────────────────
        // We keep the same stack-based prologue/epilogue structure but replace
        // virtual register references with physical registers or memory loads/stores.

        // Total stack size: base slots for spilled regs + shadow space.
        const spill_count = next_spill_slot - 1;
        var stack_size: u32 = func.stack_size;
        if (spill_count * 8 > stack_size) stack_size = spill_count * 8;
        // Align to 16 bytes.
        stack_size = (stack_size + 15) & ~@as(u32, 15);

        const rax_phys = LirRegister{ .id = @intFromEnum(RegisterId.rax), .is_physical = true };
        const r11_phys = LirRegister{ .id = @intFromEnum(RegisterId.r11), .is_physical = true };
        const rbp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rbp), .is_physical = true };
        const rsp_phys = LirRegister{ .id = @intFromEnum(RegisterId.rsp), .is_physical = true };

        // Helper: translate a virtual LirRegister into its physical assignment or
        // return a scratch register (R11 for sources, RAX for destinations).
        // If a virtual reg is spilled, the caller must emit a load/store explicitly.
        const physReg = struct {
            fn get(map: []const ?u32, r: LirRegister, scratch: LirRegister) LirRegister {
                if (r.is_physical) return r;
                if (map[r.id]) |phys| return .{ .id = phys, .is_physical = true };
                return scratch;
            }
        }.get;

        const slotOffset = struct {
            fn get(sl: []const u32, r: LirRegister) ?i32 {
                if (r.is_physical) return null;
                if (sl[r.id] == 0) return null;
                return -@as(i32, @intCast(sl[r.id] * 8));
            }
        }.get;

        var res_func = LirFunction{
            .name = try self.allocator.dupe(u8, func.name),
            .stack_size = stack_size,
        };
        errdefer res_func.deinit(self.allocator);

        // Determine which callee-saved pool registers were actually assigned.
        var used_callee_saved = std.ArrayListUnmanaged(RegisterId).empty;
        defer used_callee_saved.deinit(self.allocator);
        for (pool) |reg| {
            const reg_id_val = @intFromEnum(reg);
            var is_used = false;
            for (reg_map) |m| {
                if (m != null and m.? == reg_id_val) {
                    is_used = true;
                    break;
                }
            }
            if (is_used) {
                try used_callee_saved.append(self.allocator, reg);
            }
        }

        for (func.blocks.items, 0..) |*block, block_idx| {
            var res_block = LirBasicBlock{ .id = block.id };
            errdefer res_block.deinit(self.allocator);

            if (block_idx == 0) {
                // Prologue: save rbp and callee-saved registers, then establish frame pointer
                try res_block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.push_r),
                    .op1 = .{ .reg = rbp_phys },
                });

                // Preserve callee-saved registers used in this function
                for (used_callee_saved.items) |reg| {
                    const reg_phys = LirRegister{ .id = @intFromEnum(reg), .is_physical = true };
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.push_r),
                        .op1 = .{ .reg = reg_phys },
                    });
                }

                try res_block.instructions.append(self.allocator, .{
                    .opcode = @intFromEnum(X86Opcode.mov_rr),
                    .dest = rbp_phys,
                    .op1 = .{ .reg = rsp_phys },
                });

                if (stack_size > 0) {
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.sub_ri),
                        .dest = rsp_phys,
                        .op1 = .{ .imm_int = stack_size },
                    });
                }
            }

            for (block.instructions.items) |instr| {
                const opcode: X86Opcode = @enumFromInt(instr.opcode);

                if (opcode == .ret) {
                    // Epilogue: restore rsp to rbp, pop callee-saved registers, pop rbp, then ret
                    try res_block.instructions.append(self.allocator, .{
                        .opcode = @intFromEnum(X86Opcode.mov_rr),
                        .dest = rsp_phys,
                        .op1 = .{ .reg = rbp_phys },
                    });

                    var idx = used_callee_saved.items.len;
                    while (idx > 0) {
                        idx -= 1;
                        const reg = used_callee_saved.items[idx];
                        const reg_phys = LirRegister{ .id = @intFromEnum(reg), .is_physical = true };
                        try res_block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.pop_r),
                            .op1 = .{ .reg = reg_phys },
                        });
                    }

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

                var new_instr = instr;

                // Resolve op1 (source register).
                if (instr.op1 == .reg and !instr.op1.reg.is_physical) {
                    const vr = instr.op1.reg;
                    if (slotOffset(spill_slot, vr)) |off| {
                        try res_block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.mov_rm),
                            .dest = r11_phys,
                            .op1 = .{ .mem = .{ .base = rbp_phys, .disp = off } },
                        });
                        new_instr.op1 = .{ .reg = r11_phys };
                    } else {
                        new_instr.op1 = .{ .reg = physReg(reg_map, vr, r11_phys) };
                    }
                }

                // Resolve op2 (source register, e.g. mov_mr).
                if (instr.op2 == .reg and !instr.op2.reg.is_physical) {
                    const vr = instr.op2.reg;
                    if (slotOffset(spill_slot, vr)) |off| {
                        try res_block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.mov_rm),
                            .dest = r11_phys,
                            .op1 = .{ .mem = .{ .base = rbp_phys, .disp = off } },
                        });
                        new_instr.op2 = .{ .reg = r11_phys };
                    } else {
                        new_instr.op2 = .{ .reg = physReg(reg_map, vr, r11_phys) };
                    }
                }

                // Resolve dest register.
                var dest_spill_off: ?i32 = null;
                if (instr.dest) |d| {
                    if (!d.is_physical) {
                        if (slotOffset(spill_slot, d)) |off| {
                            dest_spill_off = off;
                            // Load old value first for read-modify-write opcodes.
                            if (destIsRead(opcode)) {
                                try res_block.instructions.append(self.allocator, .{
                                    .opcode = @intFromEnum(X86Opcode.mov_rm),
                                    .dest = rax_phys,
                                    .op1 = .{ .mem = .{ .base = rbp_phys, .disp = off } },
                                });
                            }
                            new_instr.dest = rax_phys;
                        } else {
                            if (destIsRead(opcode)) {
                                // Ensure the physical reg holds the current value.
                                new_instr.dest = .{ .id = reg_map[d.id].?, .is_physical = true };
                            } else {
                                new_instr.dest = .{ .id = reg_map[d.id].?, .is_physical = true };
                            }
                        }
                    }
                }

                try res_block.instructions.append(self.allocator, new_instr);

                // Store spilled destination back to its stack slot.
                if (dest_spill_off) |off| {
                    if (destIsWritten(opcode)) {
                        try res_block.instructions.append(self.allocator, .{
                            .opcode = @intFromEnum(X86Opcode.mov_mr),
                            .op1 = .{ .mem = .{ .base = rbp_phys, .disp = off } },
                            .op2 = .{ .reg = rax_phys },
                        });
                    }
                }
            }

            try res_func.blocks.append(self.allocator, res_block);
        }

        return res_func;
    }
};
