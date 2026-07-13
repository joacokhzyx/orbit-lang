//! orbit/src/backend/coff/coff.zig
//!
//! Generates Microsoft COFF (Common Object File Format) relocatable object files
//! for x86-64. Used by Photon Native to link with external C compilers.
//!
//! Reference: Microsoft PE and COFF Specification, Revision 11.0.

const std = @import("std");

/// COFF File Header.
pub const CoffHeader = extern struct {
    machine: u16 = 0x8664, // IMAGE_FILE_MACHINE_AMD64
    num_sections: u16,
    timestamp: u32 = 0, // Neutral timestamp for deterministic builds
    symbol_table_ptr: u32,
    num_symbols: u32,
    optional_header_size: u16 = 0, // 0 for relocatable object files
    characteristics: u16 = 0,
};

/// COFF Section Header.
pub const CoffSectionHeader = extern struct {
    name: [8]u8,
    virtual_size: u32 = 0,
    virtual_address: u32 = 0,
    raw_data_size: u32,
    raw_data_ptr: u32,
    relocations_ptr: u32 = 0,
    line_numbers_ptr: u32 = 0,
    num_relocations: u16 = 0,
    num_line_numbers: u16 = 0,
    characteristics: u32,
};

/// COFF Symbol Table Entry.
pub const CoffSymbol = extern struct {
    name: [8]u8,
    value: u32,
    section_number: i16,
    type_field: u16 = 0,
    storage_class: u8,
    num_aux_symbols: u8 = 0,
};

pub const CoffWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CoffWriter {
        return .{ .allocator = allocator };
    }

    fn writeU16(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try buffer.appendSlice(allocator, &bytes);
    }

    fn writeU32(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try buffer.appendSlice(allocator, &bytes);
    }

    /// Writes machine code bytes and symbol definitions into a COFF object file buffer.
    pub fn writeObject(self: *CoffWriter, code: []const u8, func_name: []const u8) ![]const u8 {
        var buffer = std.ArrayListUnmanaged(u8).empty;
        errdefer buffer.deinit(self.allocator);

        const num_sections = 1;
        const num_symbols = 2; // function symbol, text section symbol

        // Calculate layout offsets
        const header_size = @sizeOf(CoffHeader);
        const section_header_size = @sizeOf(CoffSectionHeader);
        const code_offset = header_size + section_header_size;
        const code_size_aligned = (code.len + 15) & ~@as(usize, 15);
        const symbol_table_offset = code_offset + code_size_aligned;

        // Write Header portably (little-endian)
        try writeU16(&buffer, self.allocator, 0x8664); // machine
        try writeU16(&buffer, self.allocator, num_sections);
        try writeU32(&buffer, self.allocator, 0); // timestamp
        try writeU32(&buffer, self.allocator, @intCast(symbol_table_offset));
        try writeU32(&buffer, self.allocator, num_symbols);
        try writeU16(&buffer, self.allocator, 0); // optional_header_size
        try writeU16(&buffer, self.allocator, 0); // characteristics

        // Write Section Header (.text)
        var name: [8]u8 = undefined;
        @memcpy(name[0..8], ".text\x00\x00\x00");
        try buffer.appendSlice(self.allocator, &name);
        try writeU32(&buffer, self.allocator, 0); // virtual_size
        try writeU32(&buffer, self.allocator, 0); // virtual_address
        try writeU32(&buffer, self.allocator, @intCast(code.len)); // raw_data_size
        try writeU32(&buffer, self.allocator, @intCast(code_offset)); // raw_data_ptr
        try writeU32(&buffer, self.allocator, 0); // relocations_ptr
        try writeU32(&buffer, self.allocator, 0); // line_numbers_ptr
        try writeU16(&buffer, self.allocator, 0); // num_relocations
        try writeU16(&buffer, self.allocator, 0); // num_line_numbers
        try writeU32(&buffer, self.allocator, 0x60000020); // characteristics (IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ)

        // Write Code section data
        try buffer.appendSlice(self.allocator, code);
        // Align section data to 16 bytes
        const padding = code_size_aligned - code.len;
        if (padding > 0) {
            try buffer.appendNTimes(self.allocator, 0, padding);
        }

        // Write Symbols
        // Symbol 1: .text section
        var sym1_name: [8]u8 = undefined;
        @memcpy(sym1_name[0..8], ".text\x00\x00\x00");
        try buffer.appendSlice(self.allocator, &sym1_name);
        try writeU32(&buffer, self.allocator, 0); // value
        try writeU16(&buffer, self.allocator, @bitCast(@as(i16, 1))); // section_number
        try writeU16(&buffer, self.allocator, 0); // type_field
        try buffer.append(self.allocator, 3); // storage_class (IMAGE_SYM_CLASS_STATIC)
        try buffer.append(self.allocator, 0); // num_aux_symbols

        // Symbol 2: function name
        var sym2_name: [8]u8 = undefined;
        @memset(&sym2_name, 0);
        const len = @min(func_name.len, 8);
        @memcpy(sym2_name[0..len], func_name[0..len]);
        try buffer.appendSlice(self.allocator, &sym2_name);
        try writeU32(&buffer, self.allocator, 0); // value
        try writeU16(&buffer, self.allocator, @bitCast(@as(i16, 1))); // section_number
        try writeU16(&buffer, self.allocator, 0); // type_field
        try buffer.append(self.allocator, 2); // storage_class (IMAGE_SYM_CLASS_EXTERNAL)
        try buffer.append(self.allocator, 0); // num_aux_symbols

        // String table is empty (0 size)
        try writeU32(&buffer, self.allocator, 4);

        return try buffer.toOwnedSlice(self.allocator);
    }
};
