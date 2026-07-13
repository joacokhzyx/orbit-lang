//! orbit/src/backend/link/archive.zig
//!
//! Parses static archive files (.a/.lib) and provides symbol-to-member indexing for lazy resolution.

const std = @import("std");
const object = @import("object.zig");
const elf_reader = @import("elf_reader.zig");
const coff_reader = @import("coff_reader.zig");

pub const Member = struct {
    name: []const u8,
    data: []const u8,
};

pub const Archive = struct {
    allocator: std.mem.Allocator,
    members: std.ArrayListUnmanaged(Member) = .empty,
    // Map from symbol name to index in members
    symbol_to_member: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *Archive) void {
        for (self.members.items) |member| {
            self.allocator.free(member.name);
        }
        self.members.deinit(self.allocator);

        var it = self.symbol_to_member.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.symbol_to_member.deinit(self.allocator);
    }
};

pub fn parseArchive(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "!<arch>\n")) {
        return error.InvalidArchiveMagic;
    }

    var archive = Archive{ .allocator = allocator };
    errdefer archive.deinit();

    var offset: usize = 8;
    var long_names: []const u8 = &.{};

    // First pass: locate "//" long names member
    while (offset + 60 <= bytes.len) {
        const header = bytes[offset .. offset + 60];
        const size_str = std.mem.trim(u8, header[48..58], " ");
        const size = std.fmt.parseInt(usize, size_str, 10) catch {
            return error.InvalidMemberSize;
        };
        const name_raw = header[0..16];

        const next_offset = offset + 60 + size;
        const padded_next_offset = (next_offset + 1) & ~@as(usize, 1);

        if (std.mem.startsWith(u8, name_raw, "// ")) {
            long_names = bytes[offset + 60 .. offset + 60 + size];
        }

        offset = padded_next_offset;
    }

    // Second pass: parse all members and build symbol mapping
    offset = 8;
    while (offset + 60 <= bytes.len) {
        const header = bytes[offset .. offset + 60];
        const size_str = std.mem.trim(u8, header[48..58], " ");
        const size = std.fmt.parseInt(usize, size_str, 10) catch {
            return error.InvalidMemberSize;
        };
        const name_raw = header[0..16];

        const next_offset = offset + 60 + size;
        const padded_next_offset = (next_offset + 1) & ~@as(usize, 1);

        var member_name: []const u8 = "";
        if (std.mem.startsWith(u8, name_raw, "/ ")) {
            // First linker member (symbol index) - skip
        } else if (std.mem.startsWith(u8, name_raw, "// ")) {
            // Long names table - skip
        } else if (name_raw[0] == '/') {
            // Long name offset
            var name_off: usize = 0;
            var pos: usize = 1;
            while (pos < 16 and name_raw[pos] != ' ' and name_raw[pos] != '/') : (pos += 1) {
                name_off = name_off * 10 + (name_raw[pos] - '0');
            }
            if (name_off < long_names.len) {
                member_name = std.mem.span(@as([*:0]const u8, @ptrCast(&long_names[name_off])));
            }
        } else {
            // Short name, ends with / or space
            var len: usize = 0;
            while (len < 16 and name_raw[len] != '/' and name_raw[len] != ' ') : (len += 1) {}
            member_name = name_raw[0..len];
        }

        if (member_name.len > 0) {
            const member_data = bytes[offset + 60 .. offset + 60 + size];
            const member_idx = @as(u32, @intCast(archive.members.items.len));

            try archive.members.append(allocator, Member{
                .name = try allocator.dupe(u8, member_name),
                .data = member_data,
            });

            // Parse symbols to build index
            if (member_data.len >= 20 and member_data[0] == 0 and member_data[1] == 0 and member_data[2] == 0xFF and member_data[3] == 0xFF) {
                // Short import member
                const sym_name = std.mem.span(@as([*:0]const u8, @ptrCast(&member_data[20])));
                const key1 = try allocator.dupe(u8, sym_name);
                try archive.symbol_to_member.put(allocator, key1, member_idx);

                const imp_name = try std.fmt.allocPrint(allocator, "__imp_{s}", .{sym_name});
                try archive.symbol_to_member.put(allocator, imp_name, member_idx);
            } else if (member_data.len >= 4) {
                if (std.mem.eql(u8, member_data[0..4], "\x7fELF")) {
                    // ELF object
                    if (elf_reader.readObject(allocator, member_data)) |obj| {
                        var o = obj;
                        defer o.deinit(allocator);
                        for (o.symbols.items) |sym| {
                            if (sym.is_defined and sym.binding != .local) {
                                const key = try allocator.dupe(u8, sym.name);
                                try archive.symbol_to_member.put(allocator, key, member_idx);
                            }
                        }
                    } else |_| {}
                } else if (std.mem.readInt(u16, member_data[0..2], .little) == 0x8664) {
                    // COFF object
                    if (coff_reader.readObject(allocator, member_data)) |obj| {
                        var o = obj;
                        defer o.deinit(allocator);
                        for (o.symbols.items) |sym| {
                            if (sym.is_defined and sym.binding != .local) {
                                const key = try allocator.dupe(u8, sym.name);
                                try archive.symbol_to_member.put(allocator, key, member_idx);
                            }
                        }
                    } else |_| {}
                }
            }
        }

        offset = padded_next_offset;
    }

    return archive;
}
