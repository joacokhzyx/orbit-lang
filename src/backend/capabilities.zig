//! orbit/src/backend/capabilities.zig
//!
//! Inspects an IRModule and reports which opcodes are not yet covered by the
//! Photon Native backend.  Used to implement --backend=auto fallback logic and
//! --backend=native hard-failure mode.

const std = @import("std");
const ir_mod = @import("../ir/ir.zig");
const IRModule = ir_mod.IRModule;
const IROpcode = ir_mod.IROpcode;

// ── Native-supported opcodes ───────────────────────────────────────────────────
// Everything NOT in this set causes a fallback or error depending on backend mode.
const NATIVE_SUPPORTED: []const IROpcode = &.{
    .nop,
    .load_const,
    .load_var,
    .store_var,
    .decl_var,
    .add,
    .sub,
    .mul,
    .div,
    .mod,
    .eq,
    .ne,
    .lt,
    .le,
    .gt,
    .ge,
    .and_op,
    .or_op,
    .not_op,
    .neg,
    .begin_block,
    .end_block,
    .call,
    .ret,
    .jump,
    .jump_if_false,
    .label,
    .copy,
    .arg,
};

fn isSupported(op: IROpcode) bool {
    for (NATIVE_SUPPORTED) |s| {
        if (s == op) return true;
    }
    return false;
}

/// Returns the name of the first unsupported opcode found, or null if all are
/// covered by the native backend.
pub fn firstUnsupported(module: *const IRModule) ?[]const u8 {
    for (module.functions.items) |func| {
        for (func.instructions.items) |instr| {
            if (!isSupported(instr.opcode)) {
                return @tagName(instr.opcode);
            }
        }
    }
    return null;
}
