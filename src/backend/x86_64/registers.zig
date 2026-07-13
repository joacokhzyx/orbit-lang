//! orbit/src/backend/x86_64/registers.zig
//!
//! Physical register definitions and ABI mappings for x86-64.
//! Defines general-purpose and XMM registers, volatile/nonvolatile status,
//! and standard calling convention mappings.
//!
//! References: Microsoft x64 Calling Convention, System V AMD64 ABI.

const std = @import("std");

/// General Purpose register codes on x86-64 (matching their machine encoding values).
pub const RegisterId = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
};

/// XMM register codes on x86-64.
pub const XmmRegisterId = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
};

/// Checks if a register is preserved (callee-saved) under Microsoft x64 calling convention.
pub fn isCalleeSavedWindows(reg: RegisterId) bool {
    return switch (reg) {
        .rbx, .rbp, .rdi, .rsi, .r12, .r13, .r14, .r15 => true,
        else => false,
    };
}

/// Checks if a register is preserved (callee-saved) under System V AMD64 calling convention.
pub fn isCalleeSavedSysV(reg: RegisterId) bool {
    return switch (reg) {
        .rbx, .rsp, .rbp, .r12, .r13, .r14, .r15 => true,
        else => false,
    };
}

/// Argument passing registers for Windows x64.
pub const windows_args = [_]RegisterId{ .rcx, .rdx, .r8, .r9 };

/// Argument passing registers for System V AMD64.
pub const sysv_args = [_]RegisterId{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
