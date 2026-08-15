//! orbit/src/backend/capabilities.zig
//!
//! Inspects an IRModule and reports which opcodes are not yet covered by the
//! Native backend.  Used to implement --backend=auto fallback logic and
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
    // F1: runtime-backed opcodes implemented in the native lowering path.
    .alloc, // → arena_alloc → call orbit_alloc
    .load_field, // → mov [obj + offset]
    .store_field, // → mov [obj + offset], value
    .list_create, // → call orbit_list_create (OrbitResult, sret)
    .list_push, // → call orbit_list_push
    .list_pop, // → call orbit_list_pop
    .list_get, // → call orbit_list_get_native
    .list_set, // → call orbit_list_set
    .list_len, // → call orbit_list_len_native
    .map_create, // → call orbit_map_create
    .map_set, // → call orbit_map_set
    .map_get, // → call orbit_map_get_native
    .map_has, // → call orbit_map_has_native
    .result_ok, // → arena-allocated OrbitResult, ok=true, value=op1
    .result_err, // → arena-allocated OrbitResult, ok=false, code=op1, msg=op2
    .result_unwrap, // → load result.value
    .result_is_ok, // → load result.ok (bool)
    .union_create, // → arena-allocated OrbitUnion, tag=op1 index, data=op2
    .union_get_tag, // → load union.tag (zero-extended int)
    .union_get_data, // → load union.data
    .db_get, // → db_query → call orbit_db_query
    .db_set, // → db_query → call orbit_db_query
    .db_all, // → db_query → call orbit_db_query
    .db_where, // → db_query → call orbit_db_query
    .http_response, // → http_write → call orbit_http_send
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
        if (func.route_info != null) {
            return "http_routes";
        }
        for (func.instructions.items) |instr| {
            if (!isSupported(instr.opcode)) {
                return @tagName(instr.opcode);
            }
        }
    }
    return null;
}
