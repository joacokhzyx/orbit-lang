//! orbit/src/backend/link/coff_writer.zig
//!
//! Generates COFF relocatable object files (.obj) for x86-64 from the neutral object model.

const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;
const Section = object.Section;
const Symbol = object.Symbol;
const Reloc = object.Reloc;
const RelocKind = object.RelocKind;

// COFF AMD64 Relocation Types
const IMAGE_REL_AMD64_ADDR64 = 0x0001;
const IMAGE_REL_AMD64_ADDR32 = 0x0002;
const IMAGE_REL_AMD64_ADDR32NB = 0x0003;
const IMAGE_REL_AMD64_REL32 = 0x0004;

// Section characteristics
const IMAGE_SCN_CNT_CODE = 0x00000020;
const IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040;
const IMAGE_SCN_CNT_UNINITIALIZED_DATA = 0x00000080;
const IMAGE_SCN_MEM_EXECUTE = 0x20000000;
const IMAGE_SCN_MEM_READ = 0x40000000;
const IMAGE_SCN_MEM_WRITE = 0x80000000;

pub const CoffHeader = extern struct {
    machine: u16 = 0x8664, // AMD64
    num_sections: u16,
    timestamp: u32 = 0,
    symbol_table_ptr: u32,
    num_symbols: u32,
    optional_header_size: u16 = 0,
    characteristics: u16 = 0,
};

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

pub const CoffSymbol = extern struct {
    name: [8]u8,
    value_bytes: [4]u8,
    section_number_bytes: [2]u8,
    type_field_bytes: [2]u8,
    storage_class: u8,
    num_aux_symbols: u8 = 0,

    pub fn getValue(self: CoffSymbol) u32 {
        return std.mem.readInt(u32, &self.value_bytes, .little);
    }
    pub fn getSectionNumber(self: CoffSymbol) i16 {
        return std.mem.readInt(i16, &self.section_number_bytes, .little);
    }
    pub fn getTypeField(self: CoffSymbol) u16 {
        return std.mem.readInt(u16, &self.type_field_bytes, .little);
    }

    pub fn init(name: [8]u8, value: u32, section_number: i16, type_field: u16, storage_class: u8, num_aux_symbols: u8) CoffSymbol {
        var sym = CoffSymbol{
            .name = name,
            .value_bytes = undefined,
            .section_number_bytes = undefined,
            .type_field_bytes = undefined,
            .storage_class = storage_class,
            .num_aux_symbols = num_aux_symbols,
        };
        std.mem.writeInt(u32, &sym.value_bytes, value, .little);
        std.mem.writeInt(i16, &sym.section_number_bytes, section_number, .little);
        std.mem.writeInt(u16, &sym.type_field_bytes, type_field, .little);
        return sym;
    }
};

pub const CoffReloc = extern struct {
    virtual_address_bytes: [4]u8,
    symbol_table_idx_bytes: [4]u8,
    type_field_bytes: [2]u8,

    pub fn getVirtualAddress(self: CoffReloc) u32 {
        return std.mem.readInt(u32, &self.virtual_address_bytes, .little);
    }
    pub fn getSymbolTableIdx(self: CoffReloc) u32 {
        return std.mem.readInt(u32, &self.symbol_table_idx_bytes, .little);
    }
    pub fn getTypeField(self: CoffReloc) u16 {
        return std.mem.readInt(u16, &self.type_field_bytes, .little);
    }

    pub fn init(virtual_address: u32, symbol_table_idx: u32, type_field: u16) CoffReloc {
        var rel = CoffReloc{
            .virtual_address_bytes = undefined,
            .symbol_table_idx_bytes = undefined,
            .type_field_bytes = undefined,
        };
        std.mem.writeInt(u32, &rel.virtual_address_bytes, virtual_address, .little);
        std.mem.writeInt(u32, &rel.symbol_table_idx_bytes, symbol_table_idx, .little);
        std.mem.writeInt(u16, &rel.type_field_bytes, type_field, .little);
        return rel;
    }
};

fn getAlignFlags(alignment: u32) u32 {
    const align_val = @max(alignment, 1);
    const power = std.math.log2(align_val);
    const align_bits = @min(power + 1, 15);
    return @as(u32, align_bits) << 20;
}

pub fn writeObject(allocator: std.mem.Allocator, obj: *const Object) ![]const u8 {
    var out_bytes = std.ArrayListUnmanaged(u8).empty;
    errdefer out_bytes.deinit(allocator);

    // 1. Build string table
    var string_table = std.ArrayListUnmanaged(u8).empty;
    defer string_table.deinit(allocator);
    // String table starts with 4-byte size field.
    try string_table.appendNTimes(allocator, 0, 4);

    // Map symbol name to its COFF symbol representation
    var coff_symbols = std.ArrayListUnmanaged(CoffSymbol).empty;
    defer coff_symbols.deinit(allocator);

    for (obj.symbols.items) |sym| {
        var name_buf: [8]u8 = @splat(0);
        if (sym.name.len <= 8) {
            @memcpy(name_buf[0..sym.name.len], sym.name);
        } else {
            // First 4 bytes are 0, next 4 are string table offset
            std.mem.writeInt(u32, name_buf[0..4], 0, .little);
            std.mem.writeInt(u32, name_buf[4..8], @intCast(string_table.items.len), .little);
            try string_table.appendSlice(allocator, sym.name);
            try string_table.append(allocator, 0);
        }

        const sec_num: i16 = if (sym.section_index) |sidx|
            @intCast(sidx + 1)
        else if (sym.is_abs)
            -1 // IMAGE_SYM_ABSOLUTE
        else
            0; // IMAGE_SYM_UNDEFINED

        const storage_class: u8 = switch (sym.binding) {
            .local => 3, // IMAGE_SYM_CLASS_STATIC
            .global, .weak => 2, // IMAGE_SYM_CLASS_EXTERNAL
        };

        // If it's a function type, set type_field to 0x20 (MSB: function)
        const type_field: u16 = if (sym.kind == .func) 0x20 else 0;

        try coff_symbols.append(allocator, CoffSymbol.init(
            name_buf,
            @intCast(sym.value),
            sec_num,
            type_field,
            storage_class,
            0,
        ));
    }

    // Set string table size
    if (string_table.items.len > 4) {
        std.mem.writeInt(u32, string_table.items[0..4], @intCast(string_table.items.len), .little);
    } else {
        // Empty string table gets size 4 (or we just don't write it, but 4 is safe)
        std.mem.writeInt(u32, string_table.items[0..4], 4, .little);
    }

    // 2. Prepare layout
    // Headers: CoffHeader (20 bytes) + SectionHeaders (40 bytes each)
    const header_size = @sizeOf(CoffHeader);
    const section_headers_size = @sizeOf(CoffSectionHeader) * obj.sections.items.len;
    const current_offset = header_size + section_headers_size;

    // Allocate output file space for headers
    try out_bytes.appendNTimes(allocator, 0, current_offset);

    var section_offsets = try allocator.alloc(u32, obj.sections.items.len);
    defer allocator.free(section_offsets);

    var reloc_offsets = try allocator.alloc(u32, obj.sections.items.len);
    defer allocator.free(reloc_offsets);

    // 3. Write section data blocks
    for (obj.sections.items, 0..) |sec, idx| {
        if (sec.kind == .bss) {
            section_offsets[idx] = 0;
            continue;
        }

        // Align raw data
        if (sec.alignment > 1) {
            const align_mask = sec.alignment - 1;
            const pad = (sec.alignment - (out_bytes.items.len & align_mask)) & align_mask;
            try out_bytes.appendNTimes(allocator, 0, @intCast(pad));
        }

        section_offsets[idx] = @intCast(out_bytes.items.len);
        try out_bytes.appendSlice(allocator, sec.bytes.items);
    }

    // 4. Write relocations
    for (obj.sections.items, 0..) |sec, idx| {
        if (sec.relocs.items.len == 0) {
            reloc_offsets[idx] = 0;
            continue;
        }

        reloc_offsets[idx] = @intCast(out_bytes.items.len);

        for (sec.relocs.items) |rel| {
            const rel_type: u16 = switch (rel.kind) {
                .ABS64 => IMAGE_REL_AMD64_ADDR64,
                .PC32, .PC32_PLT => IMAGE_REL_AMD64_REL32,
                .ABS32 => IMAGE_REL_AMD64_ADDR32,
                .RVA32 => IMAGE_REL_AMD64_ADDR32NB,
                .ABS32S => IMAGE_REL_AMD64_ADDR32, // coff doesn't differentiate ADDR32/ADDR32S
            };

            const coff_rel = CoffReloc.init(
                @intCast(rel.offset_in_section),
                rel.target_symbol_index,
                rel_type,
            );
            try out_bytes.appendSlice(allocator, std.mem.asBytes(&coff_rel));
        }
    }

    // 5. Write Symbol Table
    const symbol_table_ptr = @as(u32, @intCast(out_bytes.items.len));
    for (coff_symbols.items) |sym| {
        try out_bytes.appendSlice(allocator, std.mem.asBytes(&sym));
    }

    // 6. Write String Table
    try out_bytes.appendSlice(allocator, string_table.items);

    // 7. Write Headers
    const header = CoffHeader{
        .num_sections = @intCast(obj.sections.items.len),
        .symbol_table_ptr = symbol_table_ptr,
        .num_symbols = @intCast(coff_symbols.items.len),
    };
    @memcpy(out_bytes.items[0..header_size], std.mem.asBytes(&header));

    for (obj.sections.items, 0..) |sec, idx| {
        var name_buf: [8]u8 = @splat(0);
        const len = @min(sec.name.len, 8);
        @memcpy(name_buf[0..len], sec.name[0..len]);

        var characteristics = getAlignFlags(sec.alignment);
        switch (sec.kind) {
            .text => characteristics |= IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ,
            .rodata => characteristics |= IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
            .data => characteristics |= IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
            .bss => characteristics |= IMAGE_SCN_CNT_UNINITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
        }

        const raw_size: u32 = if (sec.kind == .bss) 0 else @intCast(sec.bytes.items.len);
        const relocs_ptr: u32 = if (sec.relocs.items.len > 0) reloc_offsets[idx] else 0;

        const sh = CoffSectionHeader{
            .name = name_buf,
            .virtual_size = @intCast(sec.bytes.items.len),
            .virtual_address = 0,
            .raw_data_size = raw_size,
            .raw_data_ptr = section_offsets[idx],
            .relocations_ptr = relocs_ptr,
            .num_relocations = @intCast(sec.relocs.items.len),
            .characteristics = characteristics,
        };
        const sh_offset = header_size + idx * @sizeOf(CoffSectionHeader);
        @memcpy(out_bytes.items[sh_offset .. sh_offset + @sizeOf(CoffSectionHeader)], std.mem.asBytes(&sh));
    }

    return out_bytes.toOwnedSlice(allocator);
}
