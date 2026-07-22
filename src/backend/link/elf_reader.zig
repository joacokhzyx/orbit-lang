//! orbit/src/backend/link/elf_reader.zig
//!
//! Parses ELF64 relocatable object files (ET_REL) into the neutral object model.

const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;
const Section = object.Section;
const Symbol = object.Symbol;
const Reloc = object.Reloc;
const RelocKind = object.RelocKind;
const elf_writer = @import("elf_writer.zig");
const Elf64Header = elf_writer.Elf64Header;
const Elf64SectionHeader = elf_writer.Elf64SectionHeader;
const Elf64Symbol = elf_writer.Elf64Symbol;
const Elf64Rela = elf_writer.Elf64Rela;

// ELF relocation types
const R_X86_64_64 = 1;
const R_X86_64_PC32 = 2;
const R_X86_64_PLT32 = 4;
const R_X86_64_32 = 10;
const R_X86_64_32S = 11;

const SHF_WRITE = 1;
const SHF_EXECINSTR = 4;

pub fn readObject(allocator: std.mem.Allocator, bytes: []const u8) !Object {
    if (bytes.len < @sizeOf(Elf64Header)) return error.BadElfHeader;
    const hdr = std.mem.bytesAsValue(Elf64Header, bytes[0..@sizeOf(Elf64Header)]);

    if (hdr.ident.magic[0] != 0x7f or hdr.ident.magic[1] != 'E' or hdr.ident.magic[2] != 'L' or hdr.ident.magic[3] != 'F') {
        return error.InvalidElfMagic;
    }
    if (hdr.type_field != 1) return error.NotRelocatableObject; // ET_REL

    const sh_table_offset = hdr.shoff;
    const sh_num = hdr.shnum;
    const sh_entry_size = hdr.shentsize;

    if (bytes.len < sh_table_offset + sh_num * sh_entry_size) return error.TruncatedElfFile;

    var sections = std.ArrayListUnmanaged(Elf64SectionHeader).empty;
    defer sections.deinit(allocator);

    var i: usize = 0;
    while (i < sh_num) : (i += 1) {
        const offset = sh_table_offset + i * sh_entry_size;
        const sh = std.mem.bytesAsValue(Elf64SectionHeader, bytes[offset .. offset + @sizeOf(Elf64SectionHeader)]);
        try sections.append(allocator, sh.*);
    }

    // Get section header names
    const shstrtab_sh = sections.items[hdr.shstrndx];
    const shstrtab_bytes = bytes[shstrtab_sh.offset .. shstrtab_sh.offset + shstrtab_sh.size];

    var obj = Object{};
    errdefer obj.deinit(allocator);

    // Map ELF section index -> neutral section index
    // Null sections or metadata sections (like symtab, strtab) map to null
    var elf_to_neutral_sec = try allocator.alloc(?u32, sh_num);
    defer allocator.free(elf_to_neutral_sec);
    @memset(elf_to_neutral_sec, null);

    // First pass: identify and create user sections
    for (sections.items, 0..) |sh, idx| {
        if (idx == 0) continue;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&shstrtab_bytes[sh.name])));

        const is_user_sec = (sh.type_field == 1 or sh.type_field == 8) and // SHT_PROGBITS or SHT_NOBITS
            !std.mem.eql(u8, name, ".shstrtab") and
            !std.mem.eql(u8, name, ".strtab") and
            !std.mem.eql(u8, name, ".symtab") and
            !std.mem.startsWith(u8, name, ".rela") and
            !std.mem.eql(u8, name, ".comment") and
            !std.mem.eql(u8, name, ".note.GNU-stack");

        if (is_user_sec) {
            const kind: object.SectionKind = if (sh.type_field == 8) .bss else if ((sh.flags & SHF_EXECINSTR) != 0) .text else if ((sh.flags & SHF_WRITE) != 0) .data else .rodata;

            var sec = Section{
                .name = try allocator.dupe(u8, name),
                .kind = kind,
                .flags = .{
                    .read = true,
                    .write = (sh.flags & SHF_WRITE) != 0,
                    .execute = (sh.flags & SHF_EXECINSTR) != 0,
                },
                .alignment = @intCast(sh.addralign),
            };
            if (sh.type_field != 8) {
                try sec.bytes.appendSlice(allocator, bytes[sh.offset .. sh.offset + sh.size]);
            } else {
                try sec.bytes.appendNTimes(allocator, 0, sh.size); // BSS initialized to zero size representation
            }

            elf_to_neutral_sec[idx] = @intCast(obj.sections.items.len);
            try obj.sections.append(allocator, sec);
        }
    }

    // Locate symbol table and its string table
    var symtab_sh_opt: ?Elf64SectionHeader = null;
    var strtab_sh_opt: ?Elf64SectionHeader = null;
    for (sections.items) |sh| {
        if (sh.type_field == 2) { // SHT_SYMTAB
            symtab_sh_opt = sh;
            strtab_sh_opt = sections.items[sh.link];
        }
    }

    if (symtab_sh_opt == null or strtab_sh_opt == null) return error.MissingSymbolTable;

    const symtab_sh = symtab_sh_opt.?;
    const strtab_sh = strtab_sh_opt.?;
    const symtab_bytes = bytes[symtab_sh.offset .. symtab_sh.offset + symtab_sh.size];
    const strtab_bytes = bytes[strtab_sh.offset .. strtab_sh.offset + strtab_sh.size];

    const num_syms = symtab_sh.size / @sizeOf(Elf64Symbol);
    var sym_idx: usize = 0;
    while (sym_idx < num_syms) : (sym_idx += 1) {
        const offset = sym_idx * @sizeOf(Elf64Symbol);
        const sym = std.mem.bytesAsValue(Elf64Symbol, symtab_bytes[offset .. offset + @sizeOf(Elf64Symbol)]);
        const sym_name = std.mem.span(@as([*:0]const u8, @ptrCast(&strtab_bytes[sym.name])));

        const binding_type = sym.info >> 4;
        const binding: object.SymbolBinding = switch (binding_type) {
            0 => .local,
            1 => .global,
            2 => .weak,
            else => .global,
        };

        const kind_type = sym.info & 0xF;
        const kind: object.SymbolKind = switch (kind_type) {
            1 => .object,
            2 => .func,
            else => .notype,
        };

        const is_defined = sym.shndx != 0; // SHN_UNDEF is 0
        const is_abs = sym.shndx == 0xFFF1; // SHN_ABS

        const section_index: ?u32 = if (is_defined and !is_abs)
            elf_to_neutral_sec[sym.shndx]
        else
            null;

        try obj.symbols.append(allocator, Symbol{
            .name = try allocator.dupe(u8, sym_name),
            .section_index = section_index,
            .is_abs = is_abs,
            .value = sym.value,
            .binding = binding,
            .kind = kind,
            .is_defined = is_defined,
            .is_extern = !is_defined,
        });
    }

    // Parse relocations (.rela sections)
    for (sections.items) |sh| {
        if (sh.type_field == 4) { // SHT_RELA
            const target_elf_idx = sh.info;
            const target_neutral_idx = elf_to_neutral_sec[target_elf_idx] orelse continue;
            var target_sec = &obj.sections.items[target_neutral_idx];

            const rela_bytes = bytes[sh.offset .. sh.offset + sh.size];
            const num_relas = sh.size / @sizeOf(Elf64Rela);

            var r_idx: usize = 0;
            while (r_idx < num_relas) : (r_idx += 1) {
                const offset = r_idx * @sizeOf(Elf64Rela);
                const rela = std.mem.bytesAsValue(Elf64Rela, rela_bytes[offset .. offset + @sizeOf(Elf64Rela)]);

                const sym_tab_idx = @as(u32, @intCast(rela.info >> 32));
                const r_type = @as(u32, @intCast(rela.info & 0xFFFFFFFF));

                const reloc_kind: RelocKind = switch (r_type) {
                    R_X86_64_64 => .ABS64,
                    R_X86_64_PC32 => .PC32,
                    R_X86_64_PLT32 => .PC32_PLT,
                    R_X86_64_32 => .ABS32,
                    R_X86_64_32S => .ABS32S,
                    else => continue, // Ignore unsupported relocations
                };

                try target_sec.relocs.append(allocator, Reloc{
                    .offset_in_section = rela.offset,
                    .target_symbol_index = sym_tab_idx,
                    .kind = reloc_kind,
                    .addend = rela.addend,
                });
            }
        }
    }

    return obj;
}
