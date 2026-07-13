//! orbit/src/backend/link/elf_writer.zig
//!
//! Generates ELF64 relocatable object files (ET_REL) for x86-64 from the neutral object model.

const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;
const Section = object.Section;
const Symbol = object.Symbol;
const Reloc = object.Reloc;
const RelocKind = object.RelocKind;
const SectionKind = object.SectionKind;

// ELF64 constants
const EI_MAG0 = 0;
const EI_MAG1 = 1;
const EI_MAG2 = 2;
const EI_MAG3 = 3;
const EI_CLASS = 4;
const EI_DATA = 5;
const EI_VERSION = 6;
const EI_OSABI = 7;
const EI_ABIVERSION = 8;

const ELFCLASS64 = 2;
const ELFDATA2LSB = 1;
const EV_CURRENT = 1;

const ET_REL = 1;
const EM_X86_64 = 62;

const SHT_NULL = 0;
const SHT_PROGBITS = 1;
const SHT_SYMTAB = 2;
const SHT_STRTAB = 3;
const SHT_RELA = 4;
const SHT_NOBITS = 8;

const SHF_WRITE = 1;
const SHF_ALLOC = 2;
const SHF_EXECINSTR = 4;
const SHF_INFO_LINK = 64;

const STB_LOCAL = 0;
const STB_GLOBAL = 1;
const STB_WEAK = 2;

const STT_NOTYPE = 0;
const STT_OBJECT = 1;
const STT_FUNC = 2;

const R_X86_64_64 = 1;
const R_X86_64_PC32 = 2;
const R_X86_64_PLT32 = 4;
const R_X86_64_32 = 10;
const R_X86_64_32S = 11;

pub const ElfIdent = extern struct {
    magic: [4]u8 = .{ 0x7f, 'E', 'L', 'F' },
    class: u8 = ELFCLASS64,
    data: u8 = ELFDATA2LSB,
    version: u8 = EV_CURRENT,
    osabi: u8 = 0,
    abiversion: u8 = 0,
    pad: [7]u8 = [_]u8{0} ** 7,
};

pub const Elf64Header = extern struct {
    ident: ElfIdent = .{},
    type_field: u16 = ET_REL,
    machine: u16 = EM_X86_64,
    version: u32 = EV_CURRENT,
    entry: u64 = 0,
    phoff: u64 = 0,
    shoff: u64,
    flags: u32 = 0,
    ehsize: u16 = @sizeOf(Elf64Header),
    phentsize: u16 = 0,
    phnum: u16 = 0,
    shentsize: u16 = @sizeOf(Elf64SectionHeader),
    shnum: u16,
    shstrndx: u16,
};

pub const Elf64SectionHeader = extern struct {
    name: u32,
    type_field: u32,
    flags: u64,
    addr: u64 = 0,
    offset: u64,
    size: u64,
    link: u32 = 0,
    info: u32 = 0,
    addralign: u64,
    entsize: u64 = 0,
};

pub const Elf64Symbol = extern struct {
    name: u32,
    info: u8,
    other: u8 = 0,
    shndx: u16,
    value: u64,
    size: u64 = 0,
};

pub const Elf64Rela = extern struct {
    offset: u64,
    info: u64,
    addend: i64,
};

pub fn writeObject(allocator: std.mem.Allocator, obj: *const Object) ![]const u8 {
    var out_bytes = std.ArrayListUnmanaged(u8).empty;
    errdefer out_bytes.deinit(allocator);

    // 1. Build string tables
    var shstrtab = std.ArrayListUnmanaged(u8).empty;
    defer shstrtab.deinit(allocator);
    try shstrtab.append(allocator, 0); // Null entry

    var strtab = std.ArrayListUnmanaged(u8).empty;
    defer strtab.deinit(allocator);
    try strtab.append(allocator, 0); // Null entry

    // Map section name -> offset in shstrtab
    var shstr_offsets = std.ArrayListUnmanaged(u32).empty;
    defer shstr_offsets.deinit(allocator);

    // Map symbol name -> offset in strtab
    var str_offsets = std.ArrayListUnmanaged(u32).empty;
    defer str_offsets.deinit(allocator);

    // 2. Prepare symbols (locals first, then globals)
    var local_symbols = std.ArrayListUnmanaged(struct { old_idx: u32, sym: Symbol }).empty;
    defer local_symbols.deinit(allocator);
    var global_symbols = std.ArrayListUnmanaged(struct { old_idx: u32, sym: Symbol }).empty;
    defer global_symbols.deinit(allocator);

    for (obj.symbols.items, 0..) |sym, i| {
        if (sym.binding == .local) {
            try local_symbols.append(allocator, .{ .old_idx = @intCast(i), .sym = sym });
        } else {
            try global_symbols.append(allocator, .{ .old_idx = @intCast(i), .sym = sym });
        }
    }

    // New symbol table layout:
    // Index 0: Undefined
    // Index 1..1+local: Locals
    // Index 1+local..: Globals/Weaks
    var final_symbols = std.ArrayListUnmanaged(Symbol).empty;
    defer final_symbols.deinit(allocator);
    // Add dummy symbol at 0
    try final_symbols.append(allocator, Symbol{
        .name = "",
        .section_index = null,
        .value = 0,
        .binding = .local,
        .kind = .notype,
        .is_defined = false,
        .is_extern = false,
    });

    var old_to_new_sym = try allocator.alloc(u32, obj.symbols.items.len);
    defer allocator.free(old_to_new_sym);

    for (local_symbols.items) |entry| {
        old_to_new_sym[entry.old_idx] = @intCast(final_symbols.items.len);
        try final_symbols.append(allocator, entry.sym);
    }
    const first_global_idx = final_symbols.items.len;
    for (global_symbols.items) |entry| {
        old_to_new_sym[entry.old_idx] = @intCast(final_symbols.items.len);
        try final_symbols.append(allocator, entry.sym);
    }

    // Add symbol names to strtab
    for (final_symbols.items) |sym| {
        if (sym.name.len == 0) {
            try str_offsets.append(allocator, 0);
        } else {
            try str_offsets.append(allocator, @intCast(strtab.items.len));
            try strtab.appendSlice(allocator, sym.name);
            try strtab.append(allocator, 0);
        }
    }

    // 3. Layout ELF sections
    // Section index 0 is SHT_NULL
    // Then we have user sections: .text, .rodata, etc.
    // Then rela sections for any section that has relocs.
    // Then .symtab, .strtab, .shstrtab
    const SectionEmit = struct {
        name_offset: u32,
        kind: SectionKind, // custom tag
        elf_type: u32,
        elf_flags: u64,
        align_val: u64,
        size: u64,
        data: []const u8,
        link: u32 = 0,
        info: u32 = 0,
        entsize: u64 = 0,
        user_sec_idx: ?u32 = null, // Ref back to object.sections if user section
    };

    var emit_secs = std.ArrayListUnmanaged(SectionEmit).empty;
    defer emit_secs.deinit(allocator);

    // Null section at 0
    try emit_secs.append(allocator, .{
        .name_offset = 0,
        .kind = .bss,
        .elf_type = SHT_NULL,
        .elf_flags = 0,
        .align_val = 0,
        .size = 0,
        .data = &.{},
    });

    // Add user sections
    for (obj.sections.items, 0..) |sec, i| {
        const name_offset = @as(u32, @intCast(shstrtab.items.len));
        try shstrtab.appendSlice(allocator, sec.name);
        try shstrtab.append(allocator, 0);

        var elf_flags: u64 = SHF_ALLOC;
        if (sec.flags.write) elf_flags |= SHF_WRITE;
        if (sec.flags.execute) elf_flags |= SHF_EXECINSTR;

        const elf_type: u32 = if (sec.kind == .bss) SHT_NOBITS else SHT_PROGBITS;

        try emit_secs.append(allocator, .{
            .name_offset = name_offset,
            .kind = sec.kind,
            .elf_type = elf_type,
            .elf_flags = elf_flags,
            .align_val = sec.alignment,
            .size = sec.bytes.items.len,
            .data = sec.bytes.items,
            .user_sec_idx = @intCast(i),
        });
    }

    // Map old section index -> ELF section index
    // Note that ELF section index at 0 is null, and user sections start at index 1.
    // So old section index `j` is at `j + 1` in our emit_secs list.

    // Add relocation (.rela) sections for user sections
    // Wait, we need to collect Rela entries first because we need their counts/sizes.
    // Let's do that.
    var rela_buffers = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Elf64Rela)).empty;
    defer {
        for (rela_buffers.items) |*buf| buf.deinit(allocator);
        rela_buffers.deinit(allocator);
    }

    for (obj.sections.items, 0..) |sec, sec_idx| {
        if (sec.relocs.items.len == 0) continue;

        var relas = std.ArrayListUnmanaged(Elf64Rela).empty;
        for (sec.relocs.items) |rel| {
            const sym_idx = old_to_new_sym[rel.target_symbol_index];
            const r_type: u64 = switch (rel.kind) {
                .ABS64 => R_X86_64_64,
                .PC32 => R_X86_64_PC32,
                .PC32_PLT => R_X86_64_PLT32,
                .ABS32 => R_X86_64_32,
                .ABS32S => R_X86_64_32S,
                .RVA32 => R_X86_64_32, // Elf doesn't have RVA32 in the same way, but map to ABS32/64
            };
            const r_info = (@as(u64, sym_idx) << 32) | r_type;
            try relas.append(allocator, .{
                .offset = rel.offset_in_section,
                .info = r_info,
                .addend = rel.addend,
            });
        }
        try rela_buffers.append(allocator, relas);

        // Add section name to shstrtab
        const name_offset = @as(u32, @intCast(shstrtab.items.len));
        const rela_name = try std.fmt.allocPrint(allocator, ".rela{s}", .{sec.name});
        defer allocator.free(rela_name);
        try shstrtab.appendSlice(allocator, rela_name);
        try shstrtab.append(allocator, 0);

        // We will append the section header later in the loop.
        // The info field will point to the target section ELF index.
        const target_elf_idx = @as(u32, @intCast(sec_idx + 1));

        const rela_bytes = std.mem.sliceAsBytes(rela_buffers.items[rela_buffers.items.len - 1].items);

        try emit_secs.append(allocator, .{
            .name_offset = name_offset,
            .kind = .rodata, // dummy kind
            .elf_type = SHT_RELA,
            .elf_flags = SHF_INFO_LINK,
            .align_val = 8,
            .size = rela_bytes.len,
            .data = rela_bytes,
            .info = target_elf_idx,
            .entsize = @sizeOf(Elf64Rela),
        });
    }

    // Now let's calculate the indices of .symtab, .strtab, .shstrtab
    const symtab_elf_idx = @as(u32, @intCast(emit_secs.items.len));
    const strtab_elf_idx = symtab_elf_idx + 1;
    const shstrtab_elf_idx = symtab_elf_idx + 2;

    // Fill in .link fields for .rela sections
    // .rela sections must point to the symbol table section
    for (emit_secs.items) |*es| {
        if (es.elf_type == SHT_RELA) {
            es.link = symtab_elf_idx;
        }
    }

    // Prepare Symbol Table data
    var symtab_data = std.ArrayListUnmanaged(u8).empty;
    defer symtab_data.deinit(allocator);
    for (final_symbols.items, 0..) |sym, i| {
        const name_off = str_offsets.items[i];
        const binding: u8 = switch (sym.binding) {
            .local => STB_LOCAL,
            .global => STB_GLOBAL,
            .weak => STB_WEAK,
        };
        const kind: u8 = switch (sym.kind) {
            .func => STT_FUNC,
            .object => STT_OBJECT,
            .notype => STT_NOTYPE,
        };
        const info = (binding << 4) | kind;

        const shndx: u16 = if (sym.section_index) |sidx|
            @intCast(sidx + 1) // 1-based section index
        else if (sym.is_abs)
            0xFFF1 // SHN_ABS
        else
            0; // SHN_UNDEF

        const elf_sym = Elf64Symbol{
            .name = name_off,
            .info = info,
            .other = 0,
            .shndx = shndx,
            .value = sym.value,
            .size = if (sym.kind == .func) 0 else 0, // could fill in if known
        };
        const sym_bytes = std.mem.asBytes(&elf_sym);
        try symtab_data.appendSlice(allocator, sym_bytes);
    }

    // Add .symtab header
    const symtab_shstr_off = @as(u32, @intCast(shstrtab.items.len));
    try shstrtab.appendSlice(allocator, ".symtab");
    try shstrtab.append(allocator, 0);

    try emit_secs.append(allocator, .{
        .name_offset = symtab_shstr_off,
        .kind = .rodata,
        .elf_type = SHT_SYMTAB,
        .elf_flags = 0,
        .align_val = 8,
        .size = symtab_data.items.len,
        .data = symtab_data.items,
        .link = strtab_elf_idx,
        .info = @intCast(first_global_idx),
        .entsize = @sizeOf(Elf64Symbol),
    });

    // Add .strtab header
    const strtab_shstr_off = @as(u32, @intCast(shstrtab.items.len));
    try shstrtab.appendSlice(allocator, ".strtab");
    try shstrtab.append(allocator, 0);

    try emit_secs.append(allocator, .{
        .name_offset = strtab_shstr_off,
        .kind = .rodata,
        .elf_type = SHT_STRTAB,
        .elf_flags = 0,
        .align_val = 1,
        .size = strtab.items.len,
        .data = strtab.items,
    });

    // Add .shstrtab header
    const shstrtab_shstr_off = @as(u32, @intCast(shstrtab.items.len));
    try shstrtab.appendSlice(allocator, ".shstrtab");
    try shstrtab.append(allocator, 0);

    try emit_secs.append(allocator, .{
        .name_offset = shstrtab_shstr_off,
        .kind = .rodata,
        .elf_type = SHT_STRTAB,
        .elf_flags = 0,
        .align_val = 1,
        .size = shstrtab.items.len,
        .data = shstrtab.items,
    });

    // 4. Serialize file layouts
    // [ELF Header] (64 bytes)
    // [Section Data Blocks] (aligned)
    // [Section Header Table]

    // Allocate placeholder for ELF header
    try out_bytes.appendNTimes(allocator, 0, @sizeOf(Elf64Header));

    var offsets = try allocator.alloc(u64, emit_secs.items.len);
    defer allocator.free(offsets);

    for (emit_secs.items, 0..) |es, idx| {
        if (es.elf_type == SHT_NULL) {
            offsets[idx] = 0;
            continue;
        }

        // Align output write pointer
        if (es.align_val > 1 and es.elf_type != SHT_NOBITS) {
            const align_mask = es.align_val - 1;
            const pad = (es.align_val - (out_bytes.items.len & align_mask)) & align_mask;
            try out_bytes.appendNTimes(allocator, 0, @intCast(pad));
        }

        offsets[idx] = out_bytes.items.len;
        if (es.elf_type != SHT_NOBITS) {
            try out_bytes.appendSlice(allocator, es.data);
        }
    }

    // Align section header table offset to 8 bytes
    const sh_align_mask = 7;
    const sh_pad = (8 - (out_bytes.items.len & sh_align_mask)) & sh_align_mask;
    try out_bytes.appendNTimes(allocator, 0, @intCast(sh_pad));
    const sh_offset = out_bytes.items.len;

    // Write section header table
    for (emit_secs.items, 0..) |es, idx| {
        const sh = Elf64SectionHeader{
            .name = es.name_offset,
            .type_field = es.elf_type,
            .flags = es.elf_flags,
            .addr = 0,
            .offset = offsets[idx],
            .size = es.size,
            .link = es.link,
            .info = es.info,
            .addralign = es.align_val,
            .entsize = es.entsize,
        };
        try out_bytes.appendSlice(allocator, std.mem.asBytes(&sh));
    }

    // Write ELF64 Header at the beginning
    const hdr = Elf64Header{
        .shoff = sh_offset,
        .shnum = @intCast(emit_secs.items.len),
        .shstrndx = @intCast(shstrtab_elf_idx),
    };
    @memcpy(out_bytes.items[0..@sizeOf(Elf64Header)], std.mem.asBytes(&hdr));

    return out_bytes.toOwnedSlice(allocator);
}
