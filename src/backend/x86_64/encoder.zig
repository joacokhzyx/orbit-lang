//! orbit/src/backend/x86_64/encoder.zig
//!
//! Encodes physical x86-64 instructions (LIR) into binary machine code bytes.
//! Supports relative jump patching and ModRM/SIB/REX encoding.
//!
//! References: Intel 64 and IA-32 Architectures Software Developer's Manual,
//! Vol 2A & 2B: Instruction Set Reference.

const std = @import("std");
const lir_mod = @import("../lir/lir.zig");
const LirInstruction = lir_mod.LirInstruction;
const LirOperand = lir_mod.LirOperand;
const LirRegister = lir_mod.LirRegister;
const LirBasicBlock = lir_mod.LirBasicBlock;
const LirFunction = lir_mod.LirFunction;

const reg_mod = @import("registers.zig");
const RegisterId = reg_mod.RegisterId;

const op_mod = @import("operands.zig");
const Rex = op_mod.Rex;
const ModRm = op_mod.ModRm;
const Sib = op_mod.Sib;
const encodeRegReg = op_mod.encodeRegReg;
const encodeRegMem = op_mod.encodeRegMem;

const inst_mod = @import("instruction.zig");
const X86Opcode = inst_mod.X86Opcode;

const object_mod = @import("../link/object.zig");
const RelocKind = object_mod.RelocKind;

pub const Encoder = struct {
    pub const SymbolReloc = struct {
        patch_offset: usize,
        symbol_name: []const u8,
        kind: RelocKind,
        addend: i64,
    };

    code: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    symbol_relocs: std.ArrayListUnmanaged(SymbolReloc),

    pub const Relocation = struct {
        patch_offset: usize, // Offset in code where the 32-bit displacement sits
        target_block_id: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .code = .empty,
            .allocator = allocator,
            .symbol_relocs = .empty,
        };
    }

    fn append(self: *Encoder, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    fn appendSlice(self: *Encoder, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    pub fn deinit(self: *Encoder) void {
        self.code.deinit(self.allocator);
        self.symbol_relocs.deinit(self.allocator);
    }

    /// Encodes a single function to machine bytes.
    pub fn encodeFunction(self: *Encoder, func: *const LirFunction) ![]const u8 {
        var block_offsets = std.AutoHashMap(u32, usize).init(self.allocator);
        defer block_offsets.deinit();

        var relocations = std.ArrayListUnmanaged(Relocation).empty;
        defer relocations.deinit(self.allocator);

        for (func.blocks.items) |*block| {
            // Record block start offset
            try block_offsets.put(block.id, self.code.items.len);

            for (block.instructions.items) |instr| {
                try self.encodeInstruction(instr, &relocations);
            }
        }

        // Patch relocations
        for (relocations.items) |rel| {
            const target_offset = block_offsets.get(rel.target_block_id) orelse 0;
            const patch_addr = rel.patch_offset;
            const next_instruction_addr = patch_addr + 4;
            const displacement = @as(i32, @intCast(target_offset)) - @as(i32, @intCast(next_instruction_addr));

            // Write 32-bit little-endian displacement
            std.mem.writeInt(i32, self.code.items[patch_addr..next_instruction_addr][0..4], displacement, .little);
        }

        return self.code.items;
    }

    fn encodeInstruction(self: *Encoder, instr: LirInstruction, relocs: *std.ArrayListUnmanaged(Relocation)) !void {
        const opcode: X86Opcode = @enumFromInt(instr.opcode);

        switch (opcode) {
            .nop => {
                try self.append(0x90);
            },
            .ret => {
                try self.append(0xC3);
            },
            .ud2 => {
                try self.appendSlice(&.{ 0x0F, 0x0B });
            },
            .push_r => {
                const reg: RegisterId = @enumFromInt(instr.op1.reg.id);
                const reg_val = @intFromEnum(reg);
                if (reg_val >= 8) {
                    const rex = Rex{ .b = true };
                    try self.append(rex.toByte());
                }
                try self.append(0x50 + @as(u8, @intCast(reg_val & 7)));
            },
            .pop_r => {
                const reg: RegisterId = @enumFromInt(instr.op1.reg.id);
                const reg_val = @intFromEnum(reg);
                if (reg_val >= 8) {
                    const rex = Rex{ .b = true };
                    try self.append(rex.toByte());
                }
                try self.append(0x58 + @as(u8, @intCast(reg_val & 7)));
            },
            .mov_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x89);
                try self.append(enc.modrm.toByte());
            },
            .mov_ri => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xB8 + @as(u8, @intCast(dest_val & 7)));

                const patch_idx = self.code.items.len;
                try self.appendSlice(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });

                if (instr.op1 == .symbol) {
                    try self.symbol_relocs.append(self.allocator, .{
                        .patch_offset = patch_idx,
                        .symbol_name = instr.op1.symbol,
                        .kind = .ABS64,
                        .addend = 0,
                    });
                } else {
                    const val = instr.op1.imm_int;
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(i64, &bytes, val, .little);
                    @memcpy(self.code.items[patch_idx..], &bytes);
                }
            },
            .mov_rm => {
                // mov reg, [base + disp] -> 0x8B
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const base: RegisterId = @enumFromInt(instr.op1.mem.base.?.id);
                const disp = instr.op1.mem.disp;

                const enc = encodeRegMem(true, dest, base, disp);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x8B);
                try self.append(enc.modrm.toByte());
                if (enc.sib) |sib| try self.append(sib.toByte());
                try self.writeDisp(disp, enc.disp_bytes);
            },
            .mov_mr => {
                // mov [base + disp], reg -> 0x89
                const base: RegisterId = @enumFromInt(instr.op1.mem.base.?.id);
                const disp = instr.op1.mem.disp;
                const src: RegisterId = @enumFromInt(instr.op2.reg.id);

                const enc = encodeRegMem(true, src, base, disp);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x89);
                try self.append(enc.modrm.toByte());
                if (enc.sib) |sib| try self.append(sib.toByte());
                try self.writeDisp(disp, enc.disp_bytes);
            },
            .movzx_rr => {
                // movzx reg64, reg8 -> 0x0F 0xB6 /r
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, dest, src);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.appendSlice(&.{ 0x0F, 0xB6 });
                try self.append(enc.modrm.toByte());
            },
            .lea => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const base: RegisterId = @enumFromInt(instr.op1.mem.base.?.id);
                const disp = instr.op1.mem.disp;

                const enc = encodeRegMem(true, dest, base, disp);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x8D);
                try self.append(enc.modrm.toByte());
                if (enc.sib) |sib| try self.append(sib.toByte());
                try self.writeDisp(disp, enc.disp_bytes);
            },
            .add_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x01);
                try self.append(enc.modrm.toByte());
            },
            .add_ri => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const val = instr.op1.imm_int;
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());

                if (val >= -128 and val <= 127) {
                    try self.append(0x83);
                    const modrm = ModRm{ .mod = 3, .reg = 0, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    try self.append(@intCast(val & 0xFF));
                } else {
                    try self.append(0x81);
                    const modrm = ModRm{ .mod = 3, .reg = 0, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &bytes, @intCast(val), .little);
                    try self.appendSlice(&bytes);
                }
            },
            .sub_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x29);
                try self.append(enc.modrm.toByte());
            },
            .sub_ri => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const val = instr.op1.imm_int;
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());

                if (val >= -128 and val <= 127) {
                    try self.append(0x83);
                    const modrm = ModRm{ .mod = 3, .reg = 5, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    try self.append(@intCast(val & 0xFF));
                } else {
                    try self.append(0x81);
                    const modrm = ModRm{ .mod = 3, .reg = 5, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &bytes, @intCast(val), .little);
                    try self.appendSlice(&bytes);
                }
            },
            .imul_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, dest, src);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.appendSlice(&.{ 0x0F, 0xAF });
                try self.append(enc.modrm.toByte());
            },
            .idiv_r => {
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const src_val = @intFromEnum(src);
                const rex = Rex{ .w = true, .b = src_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xF7);
                const modrm = ModRm{ .mod = 3, .reg = 7, .rm = @intCast(src_val & 7) };
                try self.append(modrm.toByte());
            },
            .xor_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x31);
                try self.append(enc.modrm.toByte());
            },
            .and_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x21);
                try self.append(enc.modrm.toByte());
            },
            .or_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x09);
                try self.append(enc.modrm.toByte());
            },
            .cmp_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x39);
                try self.append(enc.modrm.toByte());
            },
            .cmp_ri => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const val = instr.op1.imm_int;
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());

                if (val >= -128 and val <= 127) {
                    try self.append(0x83);
                    const modrm = ModRm{ .mod = 3, .reg = 7, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    try self.append(@intCast(val & 0xFF));
                } else {
                    try self.append(0x81);
                    const modrm = ModRm{ .mod = 3, .reg = 7, .rm = @intCast(dest_val & 7) };
                    try self.append(modrm.toByte());
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &bytes, @intCast(val), .little);
                    try self.appendSlice(&bytes);
                }
            },
            .test_rr => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const src: RegisterId = @enumFromInt(instr.op1.reg.id);
                const enc = encodeRegReg(true, src, dest);
                if (enc.rex.required()) try self.append(enc.rex.toByte());
                try self.append(0x85);
                try self.append(enc.modrm.toByte());
            },
            .sete_r, .setne_r, .setl_r, .setle_r, .setg_r, .setge_r => {
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                if (dest_val >= 4) {
                    const rex = Rex{ .b = dest_val >= 8 };
                    try self.append(rex.toByte());
                }
                try self.append(0x0F);
                const cond_byte: u8 = switch (opcode) {
                    .sete_r => 0x94,
                    .setne_r => 0x95,
                    .setl_r => 0x9C,
                    .setle_r => 0x9D,
                    .setg_r => 0x9F,
                    .setge_r => 0x9E,
                    else => unreachable,
                };
                try self.append(cond_byte);
                const modrm = ModRm{ .mod = 3, .reg = 0, .rm = @intCast(dest_val & 7) };
                try self.append(modrm.toByte());
            },
            .jmp => {
                // Near relative jump (0xE9)
                try self.append(0xE9);
                const patch_idx = self.code.items.len;
                try self.appendSlice(&.{ 0, 0, 0, 0 });
                try relocs.append(self.allocator, .{
                    .patch_offset = patch_idx,
                    .target_block_id = instr.op1.label,
                });
            },
            .je, .jne, .jl, .jle, .jg, .jge => {
                // 0x0F 0x80 + cond
                const cond_code: u8 = switch (opcode) {
                    .je => 0x84,
                    .jne => 0x85,
                    .jl => 0x8C,
                    .jle => 0x8D,
                    .jg => 0x8F,
                    .jge => 0x8E,
                    else => unreachable,
                };
                try self.appendSlice(&.{ 0x0F, cond_code });
                const patch_idx = self.code.items.len;
                try self.appendSlice(&.{ 0, 0, 0, 0 });
                try relocs.append(self.allocator, .{
                    .patch_offset = patch_idx,
                    .target_block_id = instr.op1.label,
                });
            },
            .call => {
                if (instr.op1 == .symbol) {
                    // Call by symbol: we encode an indirect call RAX placeholder or similar if external,
                    // or a dummy near relative call. Let's do direct relative E8 with symbol resolution later.
                    try self.append(0xE8);
                    const patch_idx = self.code.items.len;
                    try self.appendSlice(&.{ 0, 0, 0, 0 });
                    try self.symbol_relocs.append(self.allocator, .{
                        .patch_offset = patch_idx,
                        .symbol_name = instr.op1.symbol,
                        .kind = .PC32,
                        .addend = -4,
                    });
                } else {
                    const reg: RegisterId = @enumFromInt(instr.op1.reg.id);
                    const reg_val = @intFromEnum(reg);
                    const rex = Rex{ .b = reg_val >= 8 };
                    if (rex.required()) try self.append(rex.toByte());
                    try self.append(0xFF);
                    const modrm = ModRm{ .mod = 3, .reg = 2, .rm = @intCast(reg_val & 7) };
                    try self.append(modrm.toByte());
                }
            },
            .shl_r => {
                // shl reg, cl -> REX.W 0xD3 /4
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xD3);
                const modrm = ModRm{ .mod = 3, .reg = 4, .rm = @intCast(dest_val & 7) };
                try self.append(modrm.toByte());
            },
            .shr_r => {
                // shr reg, cl -> REX.W 0xD3 /5
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xD3);
                const modrm = ModRm{ .mod = 3, .reg = 5, .rm = @intCast(dest_val & 7) };
                try self.append(modrm.toByte());
            },
            .neg_r => {
                // neg reg -> REX.W 0xF7 /3
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xF7);
                const modrm = ModRm{ .mod = 3, .reg = 3, .rm = @intCast(dest_val & 7) };
                try self.append(modrm.toByte());
            },
            .not_r => {
                // not reg -> REX.W 0xF7 /2
                const dest: RegisterId = @enumFromInt(instr.dest.?.id);
                const dest_val = @intFromEnum(dest);
                const rex = Rex{ .w = true, .b = dest_val >= 8 };
                try self.append(rex.toByte());
                try self.append(0xF7);
                const modrm = ModRm{ .mod = 3, .reg = 2, .rm = @intCast(dest_val & 7) };
                try self.append(modrm.toByte());
            },
            .cqo => {
                // cqo -> REX.W 0x99 (sign-extend RAX into RDX:RAX)
                try self.append(0x48);
                try self.append(0x99);
            },
        }
    }

    fn writeDisp(self: *Encoder, disp: i32, bytes: u8) !void {
        if (bytes == 1) {
            try self.append(@intCast(disp & 0xFF));
        } else if (bytes == 4) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, disp, .little);
            try self.appendSlice(&b);
        }
    }
};
