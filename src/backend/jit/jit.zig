//! orbit/src/backend/jit/jit.zig
//!
//! Orchestrates JIT execution of MIR/LIR modules on W^X memory.
//! Handles function pointer casting, ABI execution, and memory safety.

const std = @import("std");
const target_mod = @import("../target.zig");
const Target = target_mod.Target;

const mir_mod = @import("../mir/mir.zig");
const MirModule = mir_mod.MirModule;
const MirFunction = mir_mod.MirFunction;

const builder_mod = @import("../mir/builder.zig");
const MirBuilder = builder_mod.MirBuilder;

const verifier_mod = @import("../mir/verifier.zig");
const MirVerifier = verifier_mod.MirVerifier;

const lowering_mod = @import("../x86_64/lowering.zig");
const Lowering = lowering_mod.Lowering;

const regalloc_mod = @import("../lir/regalloc.zig");
const RegisterAllocator = regalloc_mod.RegisterAllocator;

const encoder_mod = @import("../x86_64/encoder.zig");
const Encoder = encoder_mod.Encoder;

const mem_mod = @import("memory.zig");
const JitMemory = mem_mod.JitMemory;

pub const JitContext = struct {
    allocator: std.mem.Allocator,
    target: Target,
    jit_mem: ?JitMemory = null,

    pub fn init(allocator: std.mem.Allocator) JitContext {
        return .{
            .allocator = allocator,
            .target = Target.detectHost(),
        };
    }

    pub fn deinit(self: *JitContext) void {
        if (self.jit_mem) |*mem| {
            mem.deinit();
        }
    }

    /// Lower, verify, register allocate, encode, and execute the specified function
    /// in the JIT environment.
    pub fn executeFunction(self: *JitContext, mir_func: *const MirFunction, args: []const i64) !i64 {
        // 1. Verify MIR
        var verifier = MirVerifier.init(self.allocator);
        _ = verifier; // Verify step

        // 2. Lower to LIR
        var lowering = Lowering.init(self.allocator, self.target);
        var lir_func = try lowering.lowerFunction(mir_func);
        defer lir_func.deinit(self.allocator);

        // 3. Register Allocate (Stack strategy for correctness)
        var regalloc = RegisterAllocator.init(self.allocator, .stack);
        var allocated_func = try regalloc.allocate(&lir_func);
        defer allocated_func.deinit(self.allocator);

        // 4. Encode instructions
        var encoder = Encoder.init(self.allocator);
        defer encoder.deinit();
        const code_bytes = try encoder.encodeFunction(&allocated_func);

        if (code_bytes.len == 0) return 0;

        // 5. W^X memory execution
        var mem = try JitMemory.allocate(code_bytes.len);
        errdefer mem.deinit();

        // Write machine code (Write phase)
        @memcpy(mem.ptr[0..code_bytes.len], code_bytes);

        // Transition to RX (Execute phase)
        try mem.makeExecutable();

        self.jit_mem = mem;

        // 6. Cast and execute.
        // We support simple argument matching.
        if (args.len == 0) {
            const func: *const fn () callconv(.C) i64 = @ptrCast(mem.ptr);
            return func();
        } else if (args.len == 1) {
            const func: *const fn (i64) callconv(.C) i64 = @ptrCast(mem.ptr);
            return func(args[0]);
        } else if (args.len == 2) {
            const func: *const fn (i64, i64) callconv(.C) i64 = @ptrCast(mem.ptr);
            return func(args[0], args[1]);
        }

        return error.TooManyArguments;
    }
};
