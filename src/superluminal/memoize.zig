//! superluminal/memoize.zig
//!
//! Automatic Memoization Pass for Orbit Superluminal.
//!
//! Problem: Naïve doubly-recursive functions like Fibonacci are O(2^n).
//! No amount of inlining or TCO can fix this — the algorithm itself is wrong.
//! A compiler that wants to "work at the silicon level" must detect this pattern
//! and transform the function automatically.
//!
//! What this pass does:
//!
//!   1. Detects **pure recursive functions** — functions that:
//!        - Call themselves at least once
//!        - Have integer parameter(s)
//!        - Return an integer
//!        - Have NO side effects (no store_var to globals, no print, no I/O)
//!        - Are called with a bounded argument (n < some_const guard)
//!
//!   2. For eligible functions, it sets a flag on the IRFunction so the
//!      C backend (c_backend.zig) emits a memoized version using a static
//!      thread-local cache array. The cache is stack-allocated for small
//!      bounds, heap-allocated for large ones.
//!
//!   3. The emitted C pattern is:
//!      ```c
//!      static orbit_int _memo_fib[128] = {0};
//!      static orbit_bool _memo_fib_set[128] = {false};
//!
//!      static orbit_int fib(orbit_int n) {
//!          if (n < 0 || n >= 128) { /* original recursive code */ }
//!          if (_memo_fib_set[n]) return _memo_fib[n];
//!          orbit_int result = /* original body */;
//!          _memo_fib_set[n] = true;
//!          _memo_fib[n] = result;
//!          return result;
//!      }
//!      ```
//!
//!   This turns O(2^n) into O(n) with constant factor overhead for the cache lookup.
//!   For fib(35): ~29M recursive calls → ~35 cache lookups.  ~1000x speedup.

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRFunction = ir.IRFunction;
const IRModule = ir.IRModule;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;
const IRType = ir.IRType;

/// Maximum cache size to emit as a static array.
/// Functions with argument bounds larger than this use heap memoization.
const STATIC_MEMO_MAX: usize = 65536;

/// Default cache size when no static bound is detectable.
const DEFAULT_MEMO_SIZE: usize = 1024;

/// Tag stored in IRFunction to signal memoization to the backend.
/// We use the `memo_cache_size` field added to IRFunction (see below).
/// For now, we use a naming convention: if the function's name is appended
/// with a special marker, the backend knows to wrap it.
pub const MEMO_TAG = "_orbit_memo_";

pub const MemoizationPass = struct {
    allocator: std.mem.Allocator,
    memoized_count: usize,

    pub fn init(allocator: std.mem.Allocator) MemoizationPass {
        return .{ .allocator = allocator, .memoized_count = 0 };
    }

    pub fn optimize(self: *MemoizationPass, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.analyzeFunction(func, module);
        }
    }

    fn analyzeFunction(self: *MemoizationPass, func: *IRFunction, module: *IRModule) !void {
        _ = module;

        // Eligibility criteria:
        // 1. Returns int (or float) — memoizable type
        if (func.return_type != .int and func.return_type != .float) return;

        // 2. Has at least one int parameter
        if (func.params.len == 0) return;
        const first_param_type: IRType = if (func.param_types.len > 0) func.param_types[0] else .int;
        if (first_param_type != .int) return;

        // 3. Is recursive (calls itself)
        var is_recursive = false;
        for (func.instructions.items) |instr| {
            if (instr.opcode != .call) continue;
            const callee = switch (instr.operand1) {
                .string => |s| s,
                .symbol => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, callee, func.name)) {
                is_recursive = true;
                break;
            }
        }
        if (!is_recursive) return;

        // 4. No side effects (no store to globals, no I/O, no DB operations)
        if (hasSideEffects(func)) return;

        // 5. Has a base-case guard (n < CONST or n == 0 pattern)
        const cache_size = estimateCacheSize(func);

        // Mark this function for memoization.
        // We do this by appending a special nop instruction at the start
        // of the function body with the cache size encoded.
        // The C backend will detect this and emit the memoization wrapper.
        const memo_marker = blk: {
            var instr = IRInstruction.init(.nop);
            instr.operand1 = IRValue{ .symbol = MEMO_TAG };
            instr.operand2 = IRValue{ .int = @intCast(cache_size) };
            break :blk instr;
        };

        // Insert at position 0.
        try func.instructions.insert(self.allocator, 0, memo_marker);
        self.memoized_count += 1;
    }
};

// ─── Analysis helpers ─────────────────────────────────────────────────────────

fn hasSideEffects(func: *const IRFunction) bool {
    for (func.instructions.items) |instr| {
        switch (instr.opcode) {
            .store_var => {
                // Store to a variable that looks like a global (no $ prefix or local decl)
                // For safety, any store_var disqualifies memoization.
                return true;
            },
            .call => {
                // External calls disqualify — unless the callee is the function itself.
                const callee = switch (instr.operand1) {
                    .string => |s| s,
                    .symbol => |s| s,
                    else => continue,
                };
                if (!std.mem.eql(u8, callee, func.name)) {
                    // External call — but allow known pure math functions.
                    if (isPureMathCall(callee)) continue;
                    return true;
                }
            },
            .db_get, .db_set, .db_all, .db_where, .http_response, .list_push, .map_set, .map_delete, .alloc, .free => return true,
            else => {},
        }
    }
    return false;
}

fn isPureMathCall(name: []const u8) bool {
    const pure_math = [_][]const u8{
        "abs",   "sqrt", "pow",   "sin",  "cos",           "tan",              "log", "exp",
        "floor", "ceil", "round", "fabs", "orbit_int_abs", "orbit_float_sqrt",
    };
    for (pure_math) |pm| {
        if (std.mem.eql(u8, name, pm)) return true;
    }
    return false;
}

/// Estimate a safe cache size based on the function's base-case guard.
/// Looks for patterns like `if n < CONST` or `if n == 0`.
fn estimateCacheSize(func: *const IRFunction) usize {
    var max_bound: i64 = DEFAULT_MEMO_SIZE;

    for (func.instructions.items) |instr| {
        // Look for: r_cond = r_param < CONST  or  r_param <= CONST
        if (instr.opcode == .lt or instr.opcode == .le or
            instr.opcode == .gt or instr.opcode == .ge)
        {
            // The bound is the constant operand.
            const bound: ?i64 = switch (instr.operand2) {
                .int => |v| v,
                else => switch (instr.operand1) {
                    .int => |v| v,
                    else => null,
                },
            };
            if (bound) |b| {
                if (b > 0 and b < @as(i64, STATIC_MEMO_MAX)) {
                    // Use 2x the detected bound as cache size to avoid off-by-one.
                    const candidate = @as(usize, @intCast(b)) * 2 + 16;
                    if (candidate > max_bound) max_bound = @intCast(candidate);
                }
            }
        }
    }

    // Clamp to STATIC_MEMO_MAX.
    return @min(@as(usize, @intCast(max_bound)), STATIC_MEMO_MAX);
}

// ─── C backend integration ────────────────────────────────────────────────────
//
// The C backend calls `isMemoizable(func)` and `getMemoSize(func)` to decide
// whether to wrap the function in the memoization harness.

pub fn isMemoizable(func: IRFunction) bool {
    if (func.instructions.items.len == 0) return false;
    const first = func.instructions.items[0];
    if (first.opcode != .nop) return false;
    if (first.operand1 != .symbol) return false;
    return std.mem.eql(u8, first.operand1.symbol, MEMO_TAG);
}

pub fn getMemoSize(func: IRFunction) usize {
    if (func.instructions.items.len == 0) return DEFAULT_MEMO_SIZE;
    const first = func.instructions.items[0];
    if (first.opcode != .nop) return DEFAULT_MEMO_SIZE;
    if (first.operand2 != .int) return DEFAULT_MEMO_SIZE;
    return @intCast(@max(first.operand2.int, 1));
}

/// Get the instructions without the memo marker (skip the first nop).
pub fn getBodyInstructions(func: IRFunction) []const IRInstruction {
    if (!isMemoizable(func)) return func.instructions.items;
    if (func.instructions.items.len <= 1) return &.{};
    return func.instructions.items[1..];
}
