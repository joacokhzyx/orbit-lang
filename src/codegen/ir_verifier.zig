//! orbit/src/codegen/ir_verifier.zig
//!
//! STAB-5: type-consistency verification for the C-backend IR.
//!
//! The C backend tolerates registers whose type was never inferred (`.unknown`)
//! by falling back to unsafe lowering: `(orbit_int)(uintptr_t)(...)` casts for
//! math, `#ifndef valStr_indexOf`-style fallbacks for string methods, and
//! void* coercion for call results. That is exactly the degradation that broke
//! the self-host bootstrap (SOVER-0: `orbit_os_exec_selfhost` left untyped, so
//! `compOutput.indexOf(...)` lowered to an undeclared `compOutput_indexOf`).
//!
//! This verifier runs after codegen, so registers that codegen legitimately
//! repaired from a known callee return type are already typed. Any register
//! still `.unknown` at that point AND actually referenced as an operand is a
//! silent-miscompile hazard and fails the build.

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRModule = ir.IRModule;

pub const VerifierError = error{
    UnknownRegisterUse,
    RegisterOutOfBounds,
};

/// Opcodes whose C lowering dispatches on the operand's IR type. An
/// unknown-typed operand here silently picks a wrong lowering (int vs float vs
/// string, value casts). All other opcodes (`decl_var`, `copy`, `arg`,
/// `ret`, `load_field`, collection ops) propagate unknown registers as
/// void*-typed pointers, which is the designed behaviour of the untyped
/// list/map collections.
///
/// The untyped-collection idiom deliberately mirrors the self-hosted backend
/// (`c_backend.orb`): `+` with a string operand concatenates and passes
/// unknown operands through as string pointers; `==`/`!=` compare via pointer
/// identity when either operand is untyped; and untyped values propagate
/// freely through `decl_var`/`copy`/`arg`/`ret`/`load_field`. None of those
/// are flagged. Pure arithmetic and ordering comparisons, however, reinterpret
/// the pointer as an int via `(orbit_int)(uintptr_t)` — there is no string or
/// identity interpretation, so an unknown operand there is a real hazard.
pub fn verifyTypedIR(module: *const IRModule) VerifierError!void {
    for (module.functions.items) |func| {
        for (func.instructions.items) |instr| {
            try checkOperands(&func, instr);
        }
    }
}

fn checkOperands(func: *const ir.IRFunction, instr: ir.IRInstruction) VerifierError!void {
    switch (instr.opcode) {
        // `+` on strings lowers to orbit_string_concat; unknown operands in a
        // concat are string pointers and are fine.
        .add => {
            if (typeOfOperand(func, instr.operand1) == .string or typeOfOperand(func, instr.operand2) == .string) return;
            try checkOperand(func, instr, instr.operand1);
            try checkOperand(func, instr, instr.operand2);
        },
        .sub, .mul, .div, .mod, .lt, .le, .gt, .ge => {
            try checkOperand(func, instr, instr.operand1);
            try checkOperand(func, instr, instr.operand2);
        },
        else => {},
    }
}

fn typeOfOperand(func: *const ir.IRFunction, val: ir.IRValue) ir.IRType {
    return switch (val) {
        .register => |r| if (r < func.register_types.items.len) func.register_types.items[r] else .unknown,
        .string => .string,
        .int => .int,
        .float => .float,
        .bool => .bool,
        else => .unknown,
    };
}

fn checkOperand(func: *const ir.IRFunction, instr: ir.IRInstruction, val: ir.IRValue) VerifierError!void {
    if (val != .register) return;
    const r = val.register;
    if (r >= func.register_types.items.len) {
        std.debug.print("[ir-verifier] {s}: {s} references register r_{d} out of bounds (len={d})\n", .{
            func.name, @tagName(instr.opcode), r, func.register_types.items.len,
        });
        return error.RegisterOutOfBounds;
    }
    if (func.register_types.items[r] == .unknown) {
        var defining_opcode: []const u8 = "?";
        if (findDefiningOpcode(func, r)) |op| defining_opcode = op;
        std.debug.print("[ir-verifier] {s}: {s} uses register r_{d} (defined by {s}) with unknown type (silent-miscompile hazard)\n", .{
            func.name, @tagName(instr.opcode), r, defining_opcode,
        });
        return error.UnknownRegisterUse;
    }
}

fn findDefiningOpcode(func: *const ir.IRFunction, reg: u32) ?[]const u8 {
    for (func.instructions.items) |instr| {
        if (instr.dest != null and instr.dest.? == reg) return @tagName(instr.opcode);
    }
    return null;
}