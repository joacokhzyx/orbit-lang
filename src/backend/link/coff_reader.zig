//! orbit/src/backend/link/coff_reader.zig
//!
//! Parses COFF relocatable object files (.obj) into the neutral object model.

const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;
const Section = object.Section;
const Symbol = object.Symbol;
const Reloc = object.Reloc;
const RelocKind = object.RelocKind;
const coff_writer = @import("coff_writer.zig");
const CoffHeader = coff_writer.CoffHeader;
const CoffSectionHeader = coff_writer.CoffSectionHeader;
const CoffSymbol = coff_writer.CoffSymbol;
const CoffReloc = coff_writer.CoffReloc;

// COFF AMD64 Relocation Types
const IMAGE_REL_AMD64_ADDR64 = 0x0001;
const IMAGE_REL_AMD64_ADDR32 = 0x0002;
const IMAGE_REL_AMD64_ADDR32NB = 0x0003;
const IMAGE_REL_AMD64_REL32 = 0x0004;

pub fn readObject(allocator: std.mem.Allocator, bytes: []const u8) !Object {
    if (bytes.len < @sizeOf(CoffHeader)) return error.BadCoffHeader;
    const hdr = std.mem.bytesAsValue(CoffHeader, bytes[0..@sizeOf(CoffHeader)]);

    if (hdr.machine != 0x8664) return error.InvalidCoffMachine;

    const sh_num = hdr.num_sections;
    const symbol_table_ptr = hdr.symbol_table_ptr;
    const num_symbols = hdr.num_symbols;

    const header_size = @sizeOf(CoffHeader);
    const sh_table_offset = header_size;
    const sh_entry_size = @sizeOf(CoffSectionHeader);

    if (bytes.len < sh_table_offset + sh_num * sh_entry_size) return error.TruncatedCoffFile;

    var sections = std.ArrayListUnmanaged(CoffSectionHeader).empty;
    defer sections.deinit(allocator);

    var i: usize = 0;
    while (i < sh_num) : (i += 1) {
        const offset = sh_table_offset + i * sh_entry_size;
        const sh = std.mem.bytesAsValue(CoffSectionHeader, bytes[offset .. offset + sh_entry_size]);
        try sections.append(allocator, sh.*);
    }

    var obj = Object{};
    errdefer obj.deinit(allocator);

    // Map COFF section index -> neutral section index
    var coff_to_neutral_sec = try allocator.alloc(?u32, sh_num);
    defer allocator.free(coff_to_neutral_sec);
    @memset(coff_to_neutral_sec, null);

    // First pass: identify and create user sections
    for (sections.items, 0..) |sh, idx| {
        // Read section name (might be inline or /offset)
        var sec_name: []const u8 = undefined;
        if (sh.name[0] == '/') {
            // String table offset
            var offset_val: u32 = 0;
            var pos: usize = 1;
            while (pos < 8 and sh.name[pos] != 0 and sh.name[pos] >= '0' and sh.name[pos] <= '9') : (pos += 1) {
                offset_val = offset_val * 10 + (sh.name[pos] - '0');
            }
            // locate string table
            const strtab_offset = symbol_table_ptr + num_symbols * 18;
            const str_ptr = bytes[strtab_offset + offset_val ..];
            sec_name = std.mem.span(@as([*:0]const u8, @ptrCast(str_ptr)));
        } else {
            var len: usize = 0;
            while (len < 8 and sh.name[len] != 0) : (len += 1) {}
            sec_name = sh.name[0..len];
        }

        const is_bss = (sh.characteristics & 0x00000080) != 0; // IMAGE_SCN_CNT_UNINITIALIZED_DATA
        const kind: object.SectionKind = if (is_bss) .bss
        else if ((sh.characteristics & 0x00000020) != 0) .text // IMAGE_SCN_CNT_CODE
        else if ((sh.characteristics & 0x00200000) != 0) .rodata // IMAGE_SCN_ALIGN_2BYTES example, wait, CNT_INITIALIZED_DATA
        else if ((sh.characteristics & 0x00000040) != 0) blk: {
            if ((sh.characteristics & 0x80000000) != 0) break :blk .data;
            break :blk .rodata;
        } else .rodata;

        // Alignment value from characteristics
        const align_shift = (sh.characteristics >> 20) & 0xF;
        const alignment: u32 = if (align_shift > 0)
            @as(u32, 1) << @intCast(align_shift - 1)
        else
            1;

        var sec = Section{
            .name = try allocator.dupe(u8, sec_name),
            .kind = kind,
            .flags = .{
                .read = (sh.characteristics & 0x40000000) != 0,
                .write = (sh.characteristics & 0x80000000) != 0,
                .execute = (sh.characteristics & 0x20000000) != 0,
            },
            .alignment = alignment,
        };

        if (!is_bss and sh.raw_data_size > 0) {
            try sec.bytes.appendSlice(allocator, bytes[sh.raw_data_ptr .. sh.raw_data_ptr + sh.raw_data_size]);
        } else if (is_bss and sh.virtual_size > 0) {
            try sec.bytes.appendNTimes(allocator, 0, sh.virtual_size);
        } else if (is_bss and sh.raw_data_size > 0) {
            try sec.bytes.appendNTimes(allocator, 0, sh.raw_data_size);
        }

        coff_to_neutral_sec[idx] = @intCast(obj.sections.items.len);
        try obj.sections.append(allocator, sec);
    }

    // Locate string table
    const strtab_offset = symbol_table_ptr + num_symbols * 18;
    const strtab_bytes = bytes[strtab_offset..];

    // Read symbol table
    var s_idx: u32 = 0;
    while (s_idx < num_symbols) {
        const sym_offset = symbol_table_ptr + s_idx * 18;
        const cs = std.mem.bytesAsValue(CoffSymbol, bytes[sym_offset .. sym_offset + 18]);

        var sym_name: []const u8 = undefined;
        const cs_name = cs.name;
        if (cs_name[0] == 0 and cs_name[1] == 0 and cs_name[2] == 0 and cs_name[3] == 0) {
            const str_offset = std.mem.readInt(u32, cs_name[4..8], .little);
            sym_name = std.mem.span(@as([*:0]const u8, @ptrCast(&strtab_bytes[str_offset])));
        } else {
            var len: usize = 0;
            while (len < 8 and cs_name[len] != 0) : (len += 1) {}
            sym_name = cs_name[0..len];
        }

        const is_defined = cs.getSectionNumber() > 0;
        const is_abs = cs.getSectionNumber() == -1; // IMAGE_SYM_ABSOLUTE

        const section_index: ?u32 = if (is_defined and !is_abs)
            coff_to_neutral_sec[@intCast(cs.getSectionNumber() - 1)]
        else
            null;

        const binding: object.SymbolBinding = if (cs.storage_class == 3) .local else .global;
        const kind: object.SymbolKind = if ((cs.getTypeField() & 0xF0) == 0x20) .func else .notype;

        try obj.symbols.append(allocator, Symbol{
            .name = try allocator.dupe(u8, sym_name),
            .section_index = section_index,
            .is_abs = is_abs,
            .value = cs.getValue(),
            .binding = binding,
            .kind = kind,
            .is_defined = is_defined,
            .is_extern = !is_defined,
        });

        // Add dummy symbols for auxiliary entries to keep indices 1-to-1
        var aux: u8 = 0;
        while (aux < cs.num_aux_symbols) : (aux += 1) {
            try obj.symbols.append(allocator, Symbol{
                .name = "",
                .section_index = null,
                .value = 0,
                .binding = .local,
                .kind = .notype,
                .is_defined = false,
                .is_extern = false,
            });
        }

        s_idx += 1 + cs.num_aux_symbols;
    }

    // Parse relocations
    for (sections.items, 0..) |sh, idx| {
        if (sh.num_relocations == 0) continue;
        const target_neutral_idx = coff_to_neutral_sec[idx] orelse continue;
        var target_sec = &obj.sections.items[target_neutral_idx];

        const reloc_bytes = bytes[sh.relocations_ptr .. sh.relocations_ptr + sh.num_relocations * @sizeOf(CoffReloc)];
        var r_idx: usize = 0;
        while (r_idx < sh.num_relocations) : (r_idx += 1) {
            const offset = r_idx * @sizeOf(CoffReloc);
            const rel = std.mem.bytesAsValue(CoffReloc, reloc_bytes[offset .. offset + @sizeOf(CoffReloc)]);

            const reloc_kind: RelocKind = switch (rel.getTypeField()) {
                IMAGE_REL_AMD64_ADDR64 => .ABS64,
                IMAGE_REL_AMD64_REL32 => .PC32,
                IMAGE_REL_AMD64_ADDR32NB => .RVA32,
                IMAGE_REL_AMD64_ADDR32 => .ABS32,
                else => continue,
            };

            const virtual_address = rel.getVirtualAddress();

            // Read the implicit addend from section raw data
            var addend: i64 = 0;
            if (reloc_kind == .PC32) {
                // Read 32-bit signed implicit addend from section bytes at relocation offset.
                // IMAGE_REL_AMD64_REL32 encodes S - (P+4); our neutral model is S + A - P,
                // so we need A = implicit_addend - 4.
                if (virtual_address + 4 <= target_sec.bytes.items.len) {
                    addend = std.mem.readInt(i32, target_sec.bytes.items[virtual_address..][0..4], .little);
                    addend -= 4;
                }
            } else if (reloc_kind == .ABS64) {
                if (virtual_address + 8 <= target_sec.bytes.items.len) {
                    addend = @bitCast(std.mem.readInt(u64, target_sec.bytes.items[virtual_address..][0..8], .little));
                }
            } else if (reloc_kind == .ABS32 or reloc_kind == .RVA32) {
                if (virtual_address + 4 <= target_sec.bytes.items.len) {
                    addend = std.mem.readInt(u32, target_sec.bytes.items[virtual_address..][0..4], .little);
                }
            }

            try target_sec.relocs.append(allocator, Reloc{
                .offset_in_section = virtual_address,
                .target_symbol_index = rel.getSymbolTableIdx(),
                .kind = reloc_kind,
                .addend = addend,
            });
        }
    }

    return obj;
}
