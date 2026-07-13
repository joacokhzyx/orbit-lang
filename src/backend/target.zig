//! orbit/src/backend/target.zig
//!
//! Target architecture, ABI, and output format definitions.
//! Provides helper functions to detect the host environment and select
//! the correct compilation target.
//!
//! Reference: Intel 64 and IA-32 Architectures Software Developer's Manual
//! System V Application Binary Interface AMD64 Architecture Processor Supplement
//! Microsoft Portable Executable and Common Object File Format (PE/COFF) Spec

const std = @import("std");

/// Target Instruction Set Architecture (ISA).
pub const Isa = enum {
    x86_64,
    aarch64, // Placeholder for future expansion
};

/// Target Application Binary Interface (ABI).
pub const Abi = enum {
    windows_x64,
    sysv_amd64,
};

/// Target Binary Object/Executable Format.
pub const ObjectFormat = enum {
    coff, // Windows PE/COFF
    elf, // Linux ELF
    macho, // macOS Mach-O (planned)
    jit, // In-memory executable (W^X)
};

/// Fully resolved compilation target descriptor.
pub const Target = struct {
    isa: Isa,
    abi: Abi,
    format: ObjectFormat,

    /// Detect the current host compilation target.
    pub fn detectHost() Target {
        const builtin = @import("builtin");
        const isa: Isa = switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => .x86_64, // Default fallback
        };

        const abi: Abi = switch (builtin.os.tag) {
            .windows => .windows_x64,
            else => .sysv_amd64,
        };

        const format: ObjectFormat = switch (builtin.os.tag) {
            .windows => .coff,
            .macos => .macho,
            else => .elf,
        };

        return .{
            .isa = isa,
            .abi = abi,
            .format = format,
        };
    }

    /// Returns the target-appropriate name of a thread-local or static runtime helper.
    pub fn getRuntimeSymbolName(self: Target, base_name: []const u8) []const u8 {
        _ = self;
        return base_name;
    }
};
