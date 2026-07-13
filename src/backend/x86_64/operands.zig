//! orbit/src/backend/x86_64/operands.zig
//!
//! ModRM, SIB, and REX byte encoders for x86-64 machine instructions.
//!
//! Reference: Intel 64 and IA-32 Architectures Software Developer's Manual, Vol 2A,
//! Section 2.1: Instruction Format, ModR/M and SIB Bytes.

const std = @import("std");
const reg_mod = @import("registers.zig");
const RegisterId = reg_mod.RegisterId;

/// REX prefix helper.
pub const Rex = struct {
    w: bool = false, // 1 = 64-bit operand size
    r: bool = false, // 1 = extension of ModRM reg field (R8-R15)
    x: bool = false, // 1 = extension of SIB index field
    b: bool = false, // 1 = extension of ModRM r/m, SIB base, or opcode reg field

    pub fn toByte(self: Rex) u8 {
        var byte: u8 = 0x40;
        if (self.w) byte |= 0x08;
        if (self.r) byte |= 0x04;
        if (self.x) byte |= 0x02;
        if (self.b) byte |= 0x01;
        return byte;
    }

    pub fn required(self: Rex) bool {
        return self.w or self.r or self.x or self.b;
    }
};

/// ModR/M byte helper.
pub const ModRm = struct {
    mod: u2, // Addressing mode
    reg: u3, // Register / opcode extension
    rm: u3, // Register / memory

    pub fn toByte(self: ModRm) u8 {
        return (@as(u8, self.mod) << 6) | (@as(u8, self.reg) << 3) | self.rm;
    }
};

/// SIB (Scale-Index-Base) byte helper.
pub const Sib = struct {
    scale: u2, // Index scale (0 = 1, 1 = 2, 2 = 4, 3 = 8)
    index: u3, // Index register
    base: u3, // Base register

    pub fn toByte(self: Sib) u8 {
        return (@as(u8, self.scale) << 6) | (@as(u8, self.index) << 3) | self.base;
    }
};

/// Encode register-register or register-op extension into Rex, ModRM.
pub fn encodeRegReg(w: bool, reg: RegisterId, rm: RegisterId) struct { rex: Rex, modrm: ModRm } {
    const reg_val = @intFromEnum(reg);
    const rm_val = @intFromEnum(rm);

    return .{
        .rex = .{
            .w = w,
            .r = reg_val >= 8,
            .b = rm_val >= 8,
        },
        .modrm = .{
            .mod = 3, // Reg-to-reg mode
            .reg = @intCast(reg_val & 7),
            .rm = @intCast(rm_val & 7),
        },
    };
}

/// Encode register-memory displacement into Rex, ModRM, and optional Sib.
pub fn encodeRegMem(w: bool, reg: RegisterId, base: RegisterId, disp: i32) struct { rex: Rex, modrm: ModRm, sib: ?Sib, disp_bytes: u8 } {
    const reg_val = @intFromEnum(reg);
    const base_val = @intFromEnum(base);

    const rex = Rex{
        .w = w,
        .r = reg_val >= 8,
        .b = base_val >= 8,
    };

    var modrm = ModRm{
        .mod = 0,
        .reg = @intCast(reg_val & 7),
        .rm = @intCast(base_val & 7),
    };

    var sib: ?Sib = null;
    var disp_bytes: u8 = 0;

    // Resolve RBP or R13 addressing.
    if (base == .rbp or base == .r13) {
        modrm.mod = 1; // [RBP + disp8]
        disp_bytes = 1;
    } else if (base == .rsp or base == .r12) {
        // RSP requires SIB byte.
        modrm.rm = 4; // SIB indicator
        sib = Sib{
            .scale = 0,
            .index = 4, // No index
            .base = @intCast(base_val & 7),
        };
        if (disp == 0) {
            modrm.mod = 0;
            disp_bytes = 0;
        } else if (disp >= -128 and disp <= 127) {
            modrm.mod = 1;
            disp_bytes = 1;
        } else {
            modrm.mod = 2;
            disp_bytes = 4;
        }
    } else {
        if (disp == 0) {
            modrm.mod = 0;
            disp_bytes = 0;
        } else if (disp >= -128 and disp <= 127) {
            modrm.mod = 1;
            disp_bytes = 1;
        } else {
            modrm.mod = 2;
            disp_bytes = 4;
        }
    }

    return .{
        .rex = rex,
        .modrm = modrm,
        .sib = sib,
        .disp_bytes = disp_bytes,
    };
}
