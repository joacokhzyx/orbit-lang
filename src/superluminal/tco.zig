//! superluminal/tco.zig
//!
//! Tail-Call Optimization (TCO) pass for Orbit Superluminal.
//!
//! Two transformations are performed:
//!
//!   1. Self-recursive tail calls → parameter reassignment + backward jump.
//!      Pattern detected in IR:
//!        [arg r_a] [arg r_b] ... [call "fn" -> r_ret] [ret r_ret]
//!      Becomes: copy params → jump to function header label.
//!
//!   2. Direct tail calls to other functions (non-recursive) → mark with
//!      `__attribute__((musttail))` hint in emitted C via a special opcode.
//!      (Phase 2 extension — wired but not yet emitted as musttail.)
//!
//! After this pass the function body no longer grows the call stack for
//! tail-recursive calls, matching what GCC -O2 does with -foptimize-sibling-calls.

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRFunction = ir.IRFunction;
const IRModule = ir.IRModule;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const pass = @import("pass_runner.zig");

/// Maximum number of parameters supported for TCO rewrite.
/// Functions with more params are left untouched (conservative).
const MAX_TCO_PARAMS = 16;

/// A label id we inject at the top of the function to allow backward jumps.
/// We use a very high number unlikely to collide with codegen labels.
const TCO_LOOP_LABEL_BASE: u32 = 0xFFF0_0000;

pub const TailCallOptimizer = struct {
    allocator: std.mem.Allocator,
    tco_count: usize,

    pub fn init(allocator: std.mem.Allocator) TailCallOptimizer {
        return .{ .allocator = allocator, .tco_count = 0 };
    }

    pub fn optimize(self: *TailCallOptimizer, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *TailCallOptimizer, func: *IRFunction) !void {
        // Quick scan: is there a self-recursive tail call?
        if (!hasSelfTailCall(func)) return;
        if (func.params.len == 0 or func.params.len > MAX_TCO_PARAMS) return;

        const instrs = func.instructions.items;
        var result = std.ArrayListUnmanaged(IRInstruction).empty;
        errdefer result.deinit(self.allocator);

        // Reserve capacity estimate: original + header label + (params+1 jump) per TCO site.
        // We use append (not appendAssumeCapacity) so growth is handled automatically.
        try result.ensureTotalCapacity(self.allocator, instrs.len + 1 + func.params.len * 4);

        // Inject loop header label at position 0.
        // All tail-call sites will jump back here.
        const loop_label_id = TCO_LOOP_LABEL_BASE +% @as(u32, @truncate(@intFromPtr(func)));
        var header = IRInstruction.init(.label);
        header.operand1 = IRValue{ .label = loop_label_id };
        result.appendAssumeCapacity(header);

        // Copy all original instructions, replacing tail-call patterns.
        var i: usize = 0;
        while (i < instrs.len) {
            // Detect: [arg r0] [arg r1] ... [call "self" -> rN] [ret rN?]
            // (ret might be absent if return type is void)
            if (isTailCallSite(instrs, i, func.name)) |site| {
                // Emit: copy new_param_0 = arg_0; copy new_param_1 = arg_1; ...
                // then: jump loop_label_id
                // This replaces the stack frame reuse with a plain loop.
                for (site.arg_regs[0..site.arg_count], 0..) |arg_reg, pi| {
                    if (pi >= func.params.len) break;
                    // The parameter registers in Orbit IR are the first N registers (0..N-1).
                    var copy = IRInstruction.init(.copy);
                    copy.dest = @as(u32, @intCast(pi));
                    copy.operand1 = IRValue{ .register = arg_reg };
                    try result.append(self.allocator, copy);
                }

                var jmp = IRInstruction.init(.jump);
                jmp.operand1 = IRValue{ .label = loop_label_id };
                try result.append(self.allocator, jmp);

                // Skip past the call + optional ret
                i = site.end;
                self.tco_count += 1;
                continue;
            }

            try result.append(self.allocator, instrs[i]);
            i += 1;
        }

        // Replace the function's instruction list.
        func.instructions.deinit(self.allocator);
        func.instructions = result;
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

const TailCallSite = struct {
    /// Register values passed as arguments to the recursive call.
    arg_regs: [MAX_TCO_PARAMS]u32,
    arg_count: usize,
    /// Index past the end of the replaced region (call + optional ret).
    end: usize,
};

/// Returns non-null if position `i` is the start of a self tail-call sequence.
/// A tail call is: zero or more `arg` instructions, then a `call "self_name"`,
/// followed immediately by `ret` (which returns the call's result) or end-of-function.
fn isTailCallSite(instrs: []const IRInstruction, i: usize, func_name: []const u8) ?TailCallSite {
    if (i >= instrs.len) return null;

    // Collect consecutive arg instructions.
    var arg_regs: [MAX_TCO_PARAMS]u32 = undefined;
    var arg_count: usize = 0;
    var pos = i;

    while (pos < instrs.len and instrs[pos].opcode == .arg) {
        if (arg_count >= MAX_TCO_PARAMS) return null;
        if (instrs[pos].operand1 == .register) {
            arg_regs[arg_count] = instrs[pos].operand1.register;
        } else {
            // Argument is a constant — we can't trivially TCO this.
            return null;
        }
        arg_count += 1;
        pos += 1;
    }

    // Next must be a call to ourselves.
    if (pos >= instrs.len) return null;
    const call_instr = instrs[pos];
    if (call_instr.opcode != .call) return null;

    const callee = switch (call_instr.operand1) {
        .string => |s| s,
        .symbol => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, callee, func_name)) return null;

    const call_dest = call_instr.dest;
    pos += 1;

    // After the call there must be a `ret` that returns the call's result
    // (or the function ends — void return).
    if (pos < instrs.len) {
        const next = instrs[pos];
        if (next.opcode == .ret) {
            // Make sure it returns the call's result (or is void).
            const is_void_ret = next.operand1 == .none;
            const returns_call = call_dest != null and
                next.operand1 == .register and
                next.operand1.register == call_dest.?;
            if (!is_void_ret and !returns_call) return null;
            pos += 1; // consume the ret
        }
        // If next is NOT a ret, only accept if we're at the very last instruction
        // after the call (implicit void return pattern).
        else if (next.opcode != .ret) {
            // Only safe if there's nothing else between call and end of function.
            // For safety, require explicit ret.
            return null;
        }
    }

    return TailCallSite{
        .arg_regs = arg_regs,
        .arg_count = arg_count,
        .end = pos,
    };
}

/// Quick check: does this function contain any call to itself?
fn hasSelfTailCall(func: *const IRFunction) bool {
    const instrs = func.instructions.items;
    for (instrs, 0..) |instr, i| {
        if (instr.opcode != .call) continue;
        const callee = switch (instr.operand1) {
            .string => |s| s,
            .symbol => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, callee, func.name)) continue;
        // Check that after the call there is a ret (or end of function).
        if (i + 1 < instrs.len) {
            if (instrs[i + 1].opcode == .ret) return true;
            // Also accept call at very end with no ret (void functions).
            if (i + 1 == instrs.len) return true;
        } else {
            return true;
        }
    }
    return false;
}

// ─── Pass-runner integration ──────────────────────────────────────────────────

/// Adapter for the fixed-point pass runner interface.
/// TCO is not idempotent (it injects labels), so we run it once, not in a loop.
pub fn tailCallOptimizationPass(
    allocator: std.mem.Allocator,
    instructions: []const IRInstruction,
) anyerror!?[]IRInstruction {
    // This pass operates at module level; the per-function adapter is used
    // only when integrating via the module-level optimizer path in main.zig.
    // Return null (no change) from the per-slice interface — the real work
    // happens via TailCallOptimizer.optimize(*IRModule).
    _ = allocator;
    _ = instructions;
    return null;
}

pub const passes = [_]pass.OptimizationPass{
    .{ .name = "tco_noop", .run = tailCallOptimizationPass },
};
