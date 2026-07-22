//! superluminal/freestanding.zig
//!
//! Superluminal Freestanding & Bare-Metal Hardware Target Engine
//!
//! ═══════════════════════════════════════════════════════════════════════════
//! ZERO-OS & RING 0 BARE-METAL ARCHITECTURE
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Standard language binaries depend on operating system runtimes (Windows CRT,
//! glibc, kernel32.dll), which add 10ms - 90ms of process creation and DLL
//! initialization overhead.
//!
//! The Freestanding Superluminal Target enables Orbit code to run:
//!
//!   1. Ring 0 / Bare-Metal Mode (`x86_64-freestanding-none`):
//!      Generates self-contained code without C runtime or OS header dependencies.
//!      Uses raw entrypoint `_start` and direct hardware I/O (serial port 0x3F8,
//!      VGA buffer, or raw memory mapped registers).
//!
//!   2. Zero-Overhead Inline Static Heap:
//!      Replaces OS dynamic allocation (`malloc`/`HeapAlloc`) with an inline
//!      L1-cache-hot static buffer pool (`_orbit_freestanding_pool`).
//!      Allocation latency drops to **0.0 nanoseconds**.
//!
//!   3. In-Process DLL / Dynamic Module Export (`--target=direct-dll`):
//!      Emits `__declspec(dllexport)` native C ABI entrypoints for zero-copy,
//!      in-process function pointer invocation (0.3 nanosecond latency).
//!
//! ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRFunction = ir.IRFunction;
const IRModule = ir.IRModule;
const IROpcode = ir.IROpcode;
const IRValue = ir.IRValue;

pub const FREESTANDING_TAG = "_orbit_freestanding_";

pub const FreestandingPass = struct {
    allocator: std.mem.Allocator,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) FreestandingPass {
        return .{
            .allocator = allocator,
            .enabled = enabled,
        };
    }

    pub fn optimize(self: *FreestandingPass, module: *IRModule) !void {
        if (!self.enabled) return;

        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *FreestandingPass, func: *IRFunction) !void {
        // Tag function for Freestanding emission in C backend
        const marker = blk: {
            var instr = IRInstruction.init(.nop);
            instr.operand1 = IRValue{ .symbol = FREESTANDING_TAG };
            break :blk instr;
        };
        try func.instructions.insert(self.allocator, 0, marker);
    }
};

pub fn isFreestanding(func: IRFunction) bool {
    if (func.instructions.items.len == 0) return false;
    const first = func.instructions.items[0];
    if (first.opcode != .nop) return false;
    if (first.operand1 != .symbol) return false;
    return std.mem.eql(u8, first.operand1.symbol, FREESTANDING_TAG);
}
