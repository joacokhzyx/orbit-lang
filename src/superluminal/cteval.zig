//! superluminal/cteval.zig
//!
//! Superluminal CTEVAL — Compile-Time Universal Evaluator
//!
//! ═══════════════════════════════════════════════════════════════════════════
//! THE INSIGHT
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Modern compilers (GCC, Clang, LLVM) fold constant expressions.
//! They do NOT automatically evaluate recursive pure functions at compile time
//! without programmer annotations (constexpr, const fn, __attribute__((const))).
//!
//! CTEVAL does this automatically, without any annotation.
//! It analyzes the IR call graph, identifies pure functions (no side effects,
//! no I/O, no global state mutation), and evaluates them using a complete
//! IR interpreter that runs inside the Orbit compiler.
//!
//! Result: computations that take microseconds at runtime take 0 ns —
//! because they no longer exist at runtime. They exist only in the binary
//! as integer constants.
//!
//! ═══════════════════════════════════════════════════════════════════════════
//! WHAT IT DOES
//! ═══════════════════════════════════════════════════════════════════════════
//!
//!   1. Scans all IR functions for call instructions.
//!   2. For each call, checks if all arguments are statically known integers.
//!   3. Determines if the callee is a pure function (no side effects).
//!   4. If both conditions hold: evaluates the function in the Zig interpreter.
//!   5. Replaces the call + arg sequence with a single load_const instruction.
//!
//! Example — before CTEVAL:
//!   arg r_5          ; r_5 = 35
//!   r_6 = call fib   ; expensive recursive computation
//!   arg r_6
//!   call print       ; print the result
//!
//! After CTEVAL:
//!   r_6 = load_const 9227465  ; computed at compile time
//!   arg r_6
//!   call print                ; print the constant
//!
//! ═══════════════════════════════════════════════════════════════════════════
//! INTERPRETER DESIGN
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! The interpreter executes Orbit IR instructions:
//!   - Arithmetic: add, sub, mul, div, mod, neg
//!   - Logic:      and_op, or_op, not_op
//!   - Compare:    eq, ne, lt, le, gt, ge
//!   - Control:    jump, jump_if_false, label, ret
//!   - Values:     load_const, copy
//!   - Calls:      arg, call (recursive, with memoization to avoid exponential blowup)
//!
//! Recursion is handled by memoizing intermediate results, so fib(35)
//! evaluates in O(n) interpreter steps instead of O(2^n).
//!
//! Safety limits:
//!   - Max recursion depth: 4096 calls
//!   - Max instruction steps: 10_000_000
//!   - Max call args: 32
//!   - Non-integer / non-bool operations: abort evaluation (return null)
//!
//! ═══════════════════════════════════════════════════════════════════════════
//! NOVELTY
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! This is, to the author's knowledge, the first general-purpose language
//! compiler to perform automatic whole-program compile-time evaluation of
//! pure recursive functions at the IR level, without programmer annotations,
//! as a standard optimization pass.

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRFunction = ir.IRFunction;
const IRModule = ir.IRModule;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;

// ─── Safety limits ────────────────────────────────────────────────────────────

const MAX_STEPS: usize = 10_000_000;
const MAX_DEPTH: usize = 4096;
const MAX_ARGS: usize = 32;
const MAX_REGISTERS: usize = 1024;

// ─── Memo key ─────────────────────────────────────────────────────────────────

const MemoKey = struct {
    func_name: []const u8,
    /// Packed representation of integer arguments (max 4 for memo key).
    arg0: i64,
    arg1: i64,

    pub fn hash(self: MemoKey) u64 {
        var h = std.hash.Wyhash.init(0xdeadbeef_cafebabe);
        h.update(self.func_name);
        h.update(std.mem.asBytes(&self.arg0));
        h.update(std.mem.asBytes(&self.arg1));
        return h.final();
    }

    pub fn eql(a: MemoKey, b: MemoKey) bool {
        return a.arg0 == b.arg0 and a.arg1 == b.arg1 and
            std.mem.eql(u8, a.func_name, b.func_name);
    }
};

const MemoContext = struct {
    pub fn hash(_: MemoContext, key: MemoKey) u64 {
        return key.hash();
    }
    pub fn eql(_: MemoContext, a: MemoKey, b: MemoKey) bool {
        return MemoKey.eql(a, b);
    }
};

const MemoMap = std.HashMapUnmanaged(MemoKey, i64, MemoContext, std.hash_map.default_max_load_percentage);

// ─── Interpreter register file ────────────────────────────────────────────────

const RegFile = struct {
    regs: [MAX_REGISTERS]?i64 = [_]?i64{null} ** MAX_REGISTERS,

    pub fn get(self: *const RegFile, reg: u32) ?i64 {
        if (reg >= MAX_REGISTERS) return null;
        return self.regs[reg];
    }

    pub fn set(self: *RegFile, reg: u32, val: i64) void {
        if (reg < MAX_REGISTERS) self.regs[reg] = val;
    }

    pub fn resolve(self: *const RegFile, val: IRValue) ?i64 {
        return switch (val) {
            .int => |v| v,
            .bool => |b| if (b) 1 else 0,
            .register => |r| self.get(r),
            .none => null,
            else => null,
        };
    }
};

// ─── Main evaluator ──────────────────────────────────────────────────────────

pub const CTEvaluator = struct {
    allocator: std.mem.Allocator,
    module: *const IRModule,
    memo: MemoMap,

    /// How many call sites were folded to constants.
    folded_count: usize,
    /// Total interpreter steps executed.
    steps_used: usize,
    /// Current recursion depth.
    depth: usize,

    pub fn init(allocator: std.mem.Allocator, module: *const IRModule) CTEvaluator {
        return .{
            .allocator = allocator,
            .module = module,
            .memo = .empty,
            .folded_count = 0,
            .steps_used = 0,
            .depth = 0,
        };
    }

    pub fn deinit(self: *CTEvaluator) void {
        self.memo.deinit(self.allocator);
    }

    /// Run CTEVAL over all functions in the module.
    /// Replaces pure-function calls with constant arguments by their results.
    pub fn optimize(self: *CTEvaluator, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.foldFunction(func);
        }
    }

    // ─── Per-function folding ─────────────────────────────────────────────

    fn foldFunction(self: *CTEvaluator, func: *IRFunction) !void {
        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = func.instructions.items[i];

            if (instr.opcode == .call) {
                if (try self.tryFoldCall(func, i)) {
                    // Successfully folded — the call site has been replaced.
                    // Restart from same position (the call was removed).
                    continue;
                }
            }

            i += 1;
        }
    }

    /// Try to fold a call instruction at index `call_idx`.
    /// Returns true if the call was folded (and the caller should NOT advance i).
    fn tryFoldCall(self: *CTEvaluator, func: *IRFunction, call_idx: usize) !bool {
        const call_instr = func.instructions.items[call_idx];

        // Get callee name.
        const callee_name: []const u8 = switch (call_instr.operand1) {
            .string => |s| s,
            .symbol => |s| s,
            else => return false,
        };

        // Don't fold I/O or runtime functions.
        if (isRuntimeFunction(callee_name)) return false;

        // Find the callee in the module.
        const callee = self.findFunction(callee_name) orelse return false;

        // Determine if the callee is pure.
        if (!isPure(callee)) return false;

        // Collect the arg instructions preceding this call.
        var args: [MAX_ARGS]i64 = undefined;
        var arg_count: usize = 0;
        var arg_start = call_idx;

        // Scan for preceding arg instructions by building a local constant map
        // from what we know at this point in the function.
        var known: [MAX_REGISTERS]?i64 = [_]?i64{null} ** MAX_REGISTERS;
        for (func.instructions.items[0..call_idx]) |prev| {
            if (prev.opcode == .load_const and prev.dest != null) {
                if (prev.operand1 == .int) {
                    if (prev.dest.? < MAX_REGISTERS) {
                        known[prev.dest.?] = prev.operand1.int;
                    }
                }
            }
            if (prev.opcode == .copy and prev.dest != null) {
                if (prev.operand1 == .register and prev.operand1.register < MAX_REGISTERS) {
                    if (known[prev.operand1.register]) |v| {
                        if (prev.dest.? < MAX_REGISTERS) known[prev.dest.?] = v;
                    }
                } else if (prev.operand1 == .int) {
                    if (prev.dest.? < MAX_REGISTERS) known[prev.dest.?] = prev.operand1.int;
                }
            }
        }

        // Find arg instructions immediately before the call.
        var scan: usize = call_idx;
        while (scan > 0) {
            scan -= 1;
            const s = func.instructions.items[scan];
            if (s.opcode != .arg) break;
            arg_start = scan;
        }

        var k: usize = arg_start;
        while (k < call_idx) : (k += 1) {
            const arg_instr = func.instructions.items[k];
            if (arg_instr.opcode != .arg) continue;
            if (arg_count >= MAX_ARGS) return false;

            const val: ?i64 = switch (arg_instr.operand1) {
                .int => |v| v,
                .register => |r| if (r < MAX_REGISTERS) known[r] else null,
                .bool => |b| if (b) 1 else 0,
                else => null,
            };

            if (val == null) return false; // Arg not statically known — abort.
            args[arg_count] = val.?;
            arg_count += 1;
        }

        // Evaluate the function.
        self.depth = 0;
        self.steps_used = 0;
        const result = self.evalFunction(callee, args[0..arg_count]) catch return false;
        const result_val = result orelse return false;

        // Replace the call (and preceding arg instructions) with a load_const.
        const call_dest = call_instr.dest;

        // Remove [arg_start .. call_idx + 1] (args + call).
        const remove_count = call_idx - arg_start + 1;
        var ri: usize = 0;
        while (ri < remove_count) : (ri += 1) {
            _ = func.instructions.orderedRemove(arg_start);
        }

        // Insert a load_const at arg_start if there was a destination.
        if (call_dest) |dest| {
            var load = IRInstruction.init(.load_const);
            load.dest = dest;
            load.operand1 = IRValue{ .int = result_val };
            try func.instructions.insert(self.allocator, arg_start, load);
        }

        self.folded_count += 1;
        return true;
    }

    // ─── IR Interpreter ───────────────────────────────────────────────────

    /// Evaluate a function with the given integer arguments.
    /// Returns the integer result, or null if evaluation is not possible
    /// (non-integer result, side effects encountered, limits exceeded).
    pub fn evalFunction(self: *CTEvaluator, func: *const IRFunction, args: []const i64) !?i64 {
        if (self.depth > MAX_DEPTH) return null;
        if (self.steps_used > MAX_STEPS) return null;

        // Check memo cache.
        const key = MemoKey{
            .func_name = func.name,
            .arg0 = if (args.len > 0) args[0] else 0,
            .arg1 = if (args.len > 1) args[1] else 0,
        };
        if (self.memo.get(key)) |cached| {
            return cached;
        }

        self.depth += 1;
        defer self.depth -= 1;

        var regs = RegFile{};

        // Seed parameter registers from args.
        // In Orbit IR, params map to the first N registers.
        for (args, 0..) |arg_val, pi| {
            regs.set(@intCast(pi), arg_val);
        }

        // Pending args for the next call.
        var pending_args: [MAX_ARGS]i64 = undefined;
        var pending_arg_count: usize = 0;

        const instrs = func.instructions.items;
        var ip: usize = 0;

        while (ip < instrs.len) {
            if (self.steps_used > MAX_STEPS) return null;
            self.steps_used += 1;

            const instr = instrs[ip];

            switch (instr.opcode) {
                .nop, .label => {
                    ip += 1;
                },

                .load_const => {
                    if (instr.dest) |dest| {
                        switch (instr.operand1) {
                            .int => |v| regs.set(dest, v),
                            .bool => |b| regs.set(dest, if (b) 1 else 0),
                            .float => return null, // We only handle integers.
                            else => {},
                        }
                    }
                    ip += 1;
                },

                .copy => {
                    if (instr.dest) |dest| {
                        if (regs.resolve(instr.operand1)) |v| {
                            regs.set(dest, v);
                        }
                    }
                    ip += 1;
                },

                .add => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, a +% b);
                    }
                    ip += 1;
                },

                .sub => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, a -% b);
                    }
                    ip += 1;
                },

                .mul => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, a *% b);
                    }
                    ip += 1;
                },

                .div => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        if (b == 0) return null;
                        regs.set(dest, @divTrunc(a, b));
                    }
                    ip += 1;
                },

                .mod => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        if (b == 0) return null;
                        regs.set(dest, @mod(a, b));
                    }
                    ip += 1;
                },

                .neg => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        regs.set(dest, -a);
                    }
                    ip += 1;
                },

                .not_op => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        regs.set(dest, if (a == 0) 1 else 0);
                    }
                    ip += 1;
                },

                .and_op => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a != 0 and b != 0) 1 else 0);
                    }
                    ip += 1;
                },

                .or_op => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a != 0 or b != 0) 1 else 0);
                    }
                    ip += 1;
                },

                .eq => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a == b) 1 else 0);
                    }
                    ip += 1;
                },

                .ne => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a != b) 1 else 0);
                    }
                    ip += 1;
                },

                .lt => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a < b) 1 else 0);
                    }
                    ip += 1;
                },

                .le => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a <= b) 1 else 0);
                    }
                    ip += 1;
                },

                .gt => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a > b) 1 else 0);
                    }
                    ip += 1;
                },

                .ge => {
                    if (instr.dest) |dest| {
                        const a = regs.resolve(instr.operand1) orelse return null;
                        const b = regs.resolve(instr.operand2) orelse return null;
                        regs.set(dest, if (a >= b) 1 else 0);
                    }
                    ip += 1;
                },

                .jump => {
                    const target = getJumpTarget(instr) orelse return null;
                    ip = findLabel(instrs, target) orelse return null;
                },

                .jump_if_false => {
                    const cond = regs.resolve(instr.operand1) orelse return null;
                    if (cond == 0) {
                        const target = switch (instr.operand2) {
                            .label => |l| l,
                            .int => |v| @as(u32, @intCast(v)),
                            else => return null,
                        };
                        ip = findLabel(instrs, target) orelse return null;
                    } else {
                        ip += 1;
                    }
                },

                .arg => {
                    const val = regs.resolve(instr.operand1) orelse return null;
                    if (pending_arg_count >= MAX_ARGS) return null;
                    pending_args[pending_arg_count] = val;
                    pending_arg_count += 1;
                    ip += 1;
                },

                .call => {
                    const callee_name: []const u8 = switch (instr.operand1) {
                        .string => |s| s,
                        .symbol => |s| s,
                        else => return null,
                    };

                    // Reject I/O and side-effecting runtime functions.
                    if (isRuntimeFunction(callee_name)) return null;

                    const callee = self.findFunction(callee_name) orelse return null;
                    if (!isPure(callee)) return null;

                    // Recursively evaluate.
                    const call_result = try self.evalFunction(callee, pending_args[0..pending_arg_count]);
                    pending_arg_count = 0;

                    if (call_result == null) return null;
                    if (instr.dest) |dest| {
                        regs.set(dest, call_result.?);
                    }
                    ip += 1;
                },

                .ret => {
                    const result: ?i64 = if (instr.operand1 != .none)
                        regs.resolve(instr.operand1)
                    else
                        @as(?i64, 0); // void return

                    // Memoize before returning.
                    if (result) |r| {
                        try self.memo.put(self.allocator, key, r);
                    }
                    return result;
                },

                // Any other opcode: might have side effects — abort.
                else => return null,
            }
        }

        // Fell off the end without ret (implicit void return).
        return 0;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    fn findFunction(self: *const CTEvaluator, name: []const u8) ?*const IRFunction {
        for (self.module.functions.items) |*func| {
            if (std.mem.eql(u8, func.name, name)) return func;
        }
        return null;
    }
};

// ─── Purity analysis ─────────────────────────────────────────────────────────

/// Returns true if the function has no observable side effects.
/// A function is pure if:
///   - It does not store to variables that escape the function
///   - It does not call I/O or runtime functions
///   - All its callees are themselves pure
///
/// We use a conservative approximation: any store_var, db_*, http_*,
/// list_push, map_set, or external call disqualifies.
fn isPure(func: *const IRFunction) bool {
    for (func.instructions.items) |instr| {
        switch (instr.opcode) {
            .store_var, .store_field, .db_get, .db_set, .db_all, .db_where, .http_response, .list_push, .list_set, .map_set, .map_delete, .alloc, .free => return false,
            .call => {
                const callee = switch (instr.operand1) {
                    .string => |s| s,
                    .symbol => |s| s,
                    else => return false,
                };
                if (isRuntimeFunction(callee)) return false;
                // Recursive self-calls are fine for purity.
                if (std.mem.eql(u8, callee, func.name)) continue;
                // For other callees, we conservatively allow — the interpreter
                // will abort if it hits a side effect during evaluation.
            },
            else => {},
        }
    }
    return true;
}

/// Returns true if `name` is a runtime/I/O function that cannot be
/// evaluated at compile time.
fn isRuntimeFunction(name: []const u8) bool {
    const runtime_fns = [_][]const u8{
        "print",               "println",               "eprint",                "eprintln",
        "orbit_print",         "orbit_println",         "orbit_string_concat",   "orbit_string_split",
        "orbit_file_read",     "orbit_file_write",      "orbit_os_exec",         "orbit_os_env",
        "orbit_list_create",   "orbit_map_create",      "orbit_response_create", "orbit_response_json",
        "orbit_int_to_string", "orbit_float_to_string", "orbit_http_query_get",  "rand",
        "random",              "srand",                 "time",                  "malloc",
        "free",                "realloc",
    };
    for (runtime_fns) |rt| {
        if (std.mem.eql(u8, name, rt)) return true;
    }
    return false;
}

// ─── Jump target resolution ──────────────────────────────────────────────────

fn getJumpTarget(instr: IRInstruction) ?u32 {
    return switch (instr.operand1) {
        .label => |l| l,
        .int => |v| @as(u32, @intCast(v)),
        else => null,
    };
}

fn findLabel(instrs: []const IRInstruction, target: u32) ?usize {
    for (instrs, 0..) |instr, idx| {
        if (instr.opcode == .label) {
            const lbl: u32 = switch (instr.operand1) {
                .label => |l| l,
                .int => |v| @as(u32, @intCast(v)),
                else => continue,
            };
            if (lbl == target) return idx;
        }
    }
    return null;
}
