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

    // SSE2 Floating Point
    movsd_rr, // Move scalar double-precision (F2 0F 10 /r)
    movsd_rm, // Move scalar double-precision from memory (F2 0F 10 /r)
    movsd_mr, // Move scalar double-precision to memory (F2 0F 11 /r)
    addsd_rr, // Add scalar double-precision (F2 0F 58 /r)
    subsd_rr, // Subtract scalar double-precision (F2 0F 5C /r)
    mulsd_rr, // Multiply scalar double-precision (F2 0F 59 /r)
    divsd_rr, // Divide scalar double-precision (F2 0F 5E /r)
    movq_rr, // Move 64-bit from GPR to XMM (66 REX.W 0F 6E /r)
    ucomisd_rr, // Unordered compare scalar double (66 0F 2E /r)

    // Set-byte-on-condition for float comparisons (ucomisd sets CF/ZF).
    setb_r, // CF=1 (unsigned below / float <)
    setbe_r, // CF|ZF (unsigned below-or-equal / float <=)
    seta_r, // !CF&&!ZF (unsigned above / float >)
    setae_r, // !CF (unsigned above-or-equal / float >=)
};
