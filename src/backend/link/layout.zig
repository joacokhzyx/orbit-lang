//! orbit/src/backend/link/layout.zig
//!
//! Address and section layout calculations for output image emission.

const std = @import("std");
const object = @import("object.zig");
const SectionKind = object.SectionKind;
const SectionFlags = object.SectionFlags;

pub const MergedSection = struct {
    name: []const u8,
    kind: SectionKind,
    flags: SectionFlags,
    alignment: u32,
    virtual_address: u64 = 0,
    file_offset: u64 = 0,
    size: u64 = 0,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *MergedSection, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
};

pub const SectionLayoutMap = struct {
    // Key: "object_index,section_index" -> offset in MergedSection
    offsets: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    pub fn deinit(self: *SectionLayoutMap, allocator: std.mem.Allocator) void {
        self.offsets.deinit(allocator);
    }

    pub fn get(self: SectionLayoutMap, obj_idx: u32, sec_idx: u32) ?u64 {
        const key = (@as(u64, obj_idx) << 32) | sec_idx;
        return self.offsets.get(key);
    }

    pub fn put(self: *SectionLayoutMap, allocator: std.mem.Allocator, obj_idx: u32, sec_idx: u32, offset: u64) !void {
        const key = (@as(u64, obj_idx) << 32) | sec_idx;
        try self.offsets.put(allocator, key, offset);
    }
};

pub fn alignTo(val: u64, alignment: u64) u64 {
    if (alignment == 0) return val;
    const mask = alignment - 1;
    return (val + mask) & ~mask;
}
