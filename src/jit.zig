//! Windows JIT execution helper for the Orbit runtime.
//!
//! Allocates a region of memory with read/write/execute permissions via
//! `NtAllocateVirtualMemory`, copies machine code into it, and calls it as
//! a native C-convention function returning `i32`.
//!
//! This module is intentionally Windows-only and is used for low-level
//! performance experiments; it is not part of the standard code-generation
//! pipeline.

const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;

// ─── JIT ─────────────────────────────────────────────────────────────────────

/// Minimal JIT helper that can allocate executable memory pages and invoke
/// raw machine-code blobs on Windows via the NT virtual-memory API.
pub const JIT = struct {
    allocator: std.mem.Allocator,
    code_ptr: ?[*]u8 = null,
    code_size: usize = 0,

    /// Creates a new `JIT` instance backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) JIT {
        return .{ .allocator = allocator };
    }

    /// Releases the previously allocated executable memory region, if any.
    /// Uses `NtFreeVirtualMemory` with `MEM_RELEASE`.
    pub fn deinit(self: *JIT) void {
        if (self.code_ptr) |ptr| {
            var size: usize = 0;
            var base_addr: windows.PVOID = @ptrCast(ptr);
            _ = ntdll.NtFreeVirtualMemory(
                windows.GetCurrentProcess(),
                &base_addr,
                &size,
                .{ .RELEASE = true },
            );
        }
    }

    /// Allocates `size` bytes of memory with `EXECUTE_READWRITE` protection.
    /// Returns a writable slice covering the entire allocated region.
    /// The allocation is stored in `self.code_ptr` / `self.code_size`.
    pub fn allocateExecutable(self: *JIT, size: usize) ![]u8 {
        var base_addr_raw: usize = 0;
        var actual_size: usize = size;

        const status = ntdll.NtAllocateVirtualMemory(
            windows.GetCurrentProcess(),
            @ptrCast(&base_addr_raw),
            0,
            &actual_size,
            .{ .COMMIT = true, .RESERVE = true },
            .{ .EXECUTE_READWRITE = true },
        );

        if (status != .SUCCESS) return error.JitAllocationFailed;

        self.code_ptr = @ptrFromInt(base_addr_raw);
        self.code_size = actual_size;

        return self.code_ptr.?[0..size];
    }

    /// Copies `code` into a freshly allocated executable page and calls it
    /// as a zero-argument C-convention function that returns `i32`.
    pub fn execute(self: *JIT, code: []const u8) !i32 {
        const mem = try self.allocateExecutable(code.len);
        @memcpy(mem, code);

        const JitFunc = *const fn () callconv(.c) i32;
        const func: JitFunc = @ptrCast(mem.ptr);

        return func();
    }
};

// ─── Stencils ─────────────────────────────────────────────────────────────────

/// Pre-assembled x86-64 machine-code stencils used for JIT tests.
pub const Stencils = struct {
    /// Returns the integer `42` — `mov eax, 42; ret`.
    pub const return_42 = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    /// Returns the integer `200` — `mov eax, 200; ret`.
    pub const ping_pong = [_]u8{ 0xB8, 0xC8, 0x00, 0x00, 0x00, 0xC3 };
};
