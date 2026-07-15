//! orbit/src/backend/x86_64/instruction.zig
//!
//! Opcode definitions for the target-specific x86-64 backend.
//! Formats machine instruction types for instruction selection (lowering).

const std = @import("std");

/// Target-specific x86-64 opcodes.
pub const X86Opcode = enum(u32) {
    // Moves
    mov_rr,
    mov_rm,
    mov_mr,
    mov_ri,
    movzx_rr, // Move with zero-extend
    lea, // Load Effective Address

    // Push / Pop
    push_r,
    pop_r,

    // Arithmetic & Logic
    add_rr,
    add_ri,
    sub_rr,
    sub_ri,
    imul_rr,
    idiv_r,
    xor_rr,
    and_rr,
    or_rr,
    shl_r,
    shr_r,

    // Comparisons
    cmp_rr,
    cmp_ri,
    test_rr,
    sete_r,
    setne_r,
    setl_r,
    setle_r,
    setg_r,
    setge_r,

    // Control Flow
    jmp,
    je,
    jne,
    jl,
    jle,
    jg,
    jge,
    call,
    ret,
    nop,
    ud2, // Undefined instruction for traps/panics

    // Unary arithmetic and sign extension (added for full integer coverage).
    neg_r, // Two's-complement negation (F7 /3)
    not_r, // One's-complement negation (F7 /2)
    cqo, // Sign-extend RAX into RDX:RAX before idiv (REX.W 99)
};
