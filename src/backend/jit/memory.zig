//! orbit/src/backend/jit/memory.zig
//!
//! Multiplatform JIT memory allocator enforcing strict W^X security.
//! Allocates pages in Read/Write (RW) mode, then transitions them to Read/Execute (RX).
//!
//! References: Windows API VirtualAlloc / VirtualProtect; POSIX mmap / mprotect.

const std = @import("std");
const builtin = @import("builtin");

const windows = struct {
    extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyval, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(std.os.windows.WINAPI) ?*anyval;
    extern "kernel32" fn VirtualProtect(lpAddress: *anyval, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(std.os.windows.WINAPI) i32;
    extern "kernel32" fn VirtualFree(lpAddress: *anyval, dwSize: usize, dwFreeType: u32) callconv(std.os.windows.WINAPI) i32;
    extern "kernel32" fn FlushInstructionCache(hProcess: *anyval, lpBaseAddress: ?*anyval, dwSize: usize) callconv(std.os.windows.WINAPI) i32;
    extern "kernel32" fn GetCurrentProcess() callconv(std.os.windows.WINAPI) *anyval;

    const MEM_COMMIT = 0x1000;
    const MEM_RESERVE = 0x2000;
    const MEM_RELEASE = 0x8000;
    const PAGE_READWRITE = 0x04;
    const PAGE_EXECUTE_READ = 0x20;
};

pub const JitMemory = struct {
    ptr: [*]u8,
    size: usize,
    state: enum { rw, rx, freed },

    /// Allocates `size` bytes of memory in Read/Write mode.
    pub fn allocate(size: usize) !JitMemory {
        const aligned_size = (size + 4095) & ~@as(usize, 4095);

        if (builtin.os.tag == .windows) {
            const raw = windows.VirtualAlloc(null, aligned_size, windows.MEM_COMMIT | windows.MEM_RESERVE, windows.PAGE_READWRITE);
            if (raw == null) return error.OutOfMemory;
            return JitMemory{
                .ptr = @ptrCast(raw.?),
                .size = aligned_size,
                .state = .rw,
            };
        } else {
            // POSIX mmap
            const prot = std.os.linux.PROT.READ | std.os.linux.PROT.WRITE;
            const flags = std.os.linux.MAP.PRIVATE | std.os.linux.MAP.ANONYMOUS;
            const raw_addr = std.os.linux.mmap(null, aligned_size, prot, flags, -1, 0);
            if (raw_addr == -1) return error.OutOfMemory;
            return JitMemory{
                .ptr = @ptrFromInt(raw_addr),
                .size = aligned_size,
                .state = .rw,
            };
        }
    }

    /// Makes the allocated memory Read/Execute (RX) only, enforcing W^X.
    pub fn makeExecutable(self: *JitMemory) !void {
        if (self.state != .rw) return error.InvalidState;

        if (builtin.os.tag == .windows) {
            var old_protect: u32 = 0;
            const res = windows.VirtualProtect(self.ptr, self.size, windows.PAGE_EXECUTE_READ, &old_protect);
            if (res == 0) return error.PermissionDenied;

            // Flush CPU instruction cache
            const proc = windows.GetCurrentProcess();
            _ = windows.FlushInstructionCache(proc, self.ptr, self.size);

            self.state = .rx;
        } else {
            // POSIX mprotect
            const prot = std.os.linux.PROT.READ | std.os.linux.PROT.EXEC;
            const res = std.os.linux.mprotect(self.ptr, self.size, prot);
            if (res != 0) return error.PermissionDenied;
            self.state = .rx;
        }
    }

    /// Frees the allocated memory back to the operating system.
    pub fn deinit(self: *JitMemory) void {
        if (self.state == .freed) return;

        if (builtin.os.tag == .windows) {
            _ = windows.VirtualFree(self.ptr, 0, windows.MEM_RELEASE);
        } else {
            _ = std.os.linux.munmap(self.ptr, self.size);
        }
        self.state = .freed;
    }
};
