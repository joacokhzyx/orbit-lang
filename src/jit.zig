const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;

pub const JIT = struct {
    allocator: std.mem.Allocator,
    code_ptr: ?[*]u8 = null,
    code_size: usize = 0,

    pub fn init(allocator: std.mem.Allocator) JIT {
        return .{ .allocator = allocator };
    }

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

    pub fn execute(self: *JIT, code: []const u8) !i32 {
        const mem = try self.allocateExecutable(code.len);
        @memcpy(mem, code);

        const JitFunc = *const fn () callconv(.c) i32;
        const func: JitFunc = @ptrCast(mem.ptr);

        return func();
    }
};

pub const Stencils = struct {
    pub const return_42 = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    pub const ping_pong = [_]u8{ 0xB8, 0xC8, 0x00, 0x00, 0x00, 0xC3 }; 
};
