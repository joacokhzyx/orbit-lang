//! orbit/src/backend/link/reloc.zig
//!
//! Relocation kinds mapping and mathematics.

const std = @import("std");
const object = @import("object.zig");
const RelocKind = object.RelocKind;

pub fn applyReloc(kind: RelocKind, patch_bytes: []u8, S: u64, A: i64, P: u64, image_base: u64) !void {
    switch (kind) {
        .ABS64 => {
            if (patch_bytes.len < 8) return error.RelocationSizeMismatch;
            const val = @as(u64, @bitCast(@as(i64, @intCast(S)) + A));
            std.mem.writeInt(u64, patch_bytes[0..8], val, .little);
        },
        .PC32, .PC32_PLT => {
            if (patch_bytes.len < 4) return error.RelocationSizeMismatch;
            const val = @as(i64, @intCast(S)) + A - @as(i64, @intCast(P));
            if (val < -2147483648 or val > 2147483647) {
                return error.RelocationOverflow;
            }
            std.mem.writeInt(i32, patch_bytes[0..4], @intCast(val), .little);
        },
        .ABS32 => {
            if (patch_bytes.len < 4) return error.RelocationSizeMismatch;
            const val = @as(i64, @intCast(S)) + A;
            if (val < 0 or val > 4294967295) {
                return error.RelocationOverflow;
            }
            std.mem.writeInt(u32, patch_bytes[0..4], @intCast(val), .little);
        },
        .ABS32S => {
            if (patch_bytes.len < 4) return error.RelocationSizeMismatch;
            const val = @as(i64, @intCast(S)) + A;
            if (val < -2147483648 or val > 2147483647) {
                return error.RelocationOverflow;
            }
            std.mem.writeInt(i32, patch_bytes[0..4], @intCast(val), .little);
        },
        .RVA32 => {
            if (patch_bytes.len < 4) return error.RelocationSizeMismatch;
            const val = @as(i64, @intCast(S)) + A - @as(i64, @intCast(image_base));
            if (val < -2147483648 or val > 2147483647) {
                return error.RelocationOverflow;
            }
            std.mem.writeInt(u32, patch_bytes[0..4], @intCast(val), .little);
        },
    }
}
