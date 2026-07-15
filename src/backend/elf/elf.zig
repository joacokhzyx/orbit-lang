//! orbit/src/backend/elf/elf.zig
//!
//! Generates ELF64 (Executable and Linkable Format) relocatable object files
//! for x86-64 Linux/POSIX targets.
//!
//! Reference: System V Application Binary Interface, Edition 4.1.

const std = @import("std");

/// ELF64 Identification fields.
pub const ElfIdent = extern struct {
    magic: [4]u8 = .{ 0x7f, 'E', 'L', 'F' },
    class: u8 = 2, // 64-bit
    data: u8 = 1, // Little-endian
    version: u8 = 1,
    osabi: u8 = 0,
    abiversion: u8 = 0,
    pad: [7]u8 = @splat(0),
};

/// ELF64 File Header.
pub const Elf64Header = extern struct {
    ident: ElfIdent = .{},
    type_field: u16 = 1, // ET_REL
    machine: u16 = 62, // EM_X86_64
    version: u32 = 1,
    entry: u64 = 0,
    phoff: u64 = 0,
    shoff: u64,
    flags: u32 = 0,
    ehsize: u16 = 64,
    phentsize: u16 = 0,
    phnum: u16 = 0,
    shentsize: u16 = 64,
    shnum: u16,
    shstrndx: u16,
};

/// ELF64 Section Header.
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

/// ELF64 Symbol Table Entry.
pub const Elf64Symbol = extern struct {
    name: u32,
    info: u8,
    other: u8 = 0,
    shndx: u16,
    value: u64,
    size: u64 = 0,
};

pub const ElfWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ElfWriter {
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

    fn writeU64(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try buffer.appendSlice(allocator, &bytes);
    }

    fn writeIdent(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try buffer.appendSlice(allocator, &.{ 0x7f, 'E', 'L', 'F' });
        try buffer.append(allocator, 2); // class: 64-bit
        try buffer.append(allocator, 1); // data: Little-endian
        try buffer.append(allocator, 1); // version
        try buffer.append(allocator, 0); // osabi
        try buffer.append(allocator, 0); // abiversion
        try buffer.appendNTimes(allocator, 0, 7); // pad
    }

    fn writeHeader(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, shoff: u64, shnum: u16, shstrndx: u16) !void {
        try writeIdent(buffer, allocator);
        try writeU16(buffer, allocator, 1); // type: ET_REL
        try writeU16(buffer, allocator, 62); // machine: EM_X86_64
        try writeU32(buffer, allocator, 1); // version
        try writeU64(buffer, allocator, 0); // entry
        try writeU64(buffer, allocator, 0); // phoff
        try writeU64(buffer, allocator, shoff);
        try writeU32(buffer, allocator, 0); // flags
        try writeU16(buffer, allocator, 64); // ehsize
        try writeU16(buffer, allocator, 0); // phentsize
        try writeU16(buffer, allocator, 0); // phnum
        try writeU16(buffer, allocator, 64); // shentsize
        try writeU16(buffer, allocator, shnum);
        try writeU16(buffer, allocator, shstrndx);
    }

    fn writeSectionHeader(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, sh: Elf64SectionHeader) !void {
        try writeU32(buffer, allocator, sh.name);
        try writeU32(buffer, allocator, sh.type_field);
        try writeU64(buffer, allocator, sh.flags);
        try writeU64(buffer, allocator, sh.addr);
        try writeU64(buffer, allocator, sh.offset);
        try writeU64(buffer, allocator, sh.size);
        try writeU32(buffer, allocator, sh.link);
        try writeU32(buffer, allocator, sh.info);
        try writeU64(buffer, allocator, sh.addralign);
        try writeU64(buffer, allocator, sh.entsize);
    }

    fn writeSymbol(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, sym: Elf64Symbol) !void {
        try writeU32(buffer, allocator, sym.name);
        try buffer.append(allocator, sym.info);
        try buffer.append(allocator, sym.other);
        try writeU16(buffer, allocator, sym.shndx);
        try writeU64(buffer, allocator, sym.value);
        try writeU64(buffer, allocator, sym.size);
    }

    /// Writes machine code bytes and symbol definitions into an ELF64 object file buffer.
    pub fn writeObject(self: *ElfWriter, code: []const u8, func_name: []const u8) ![]const u8 {
        var buffer = std.ArrayListUnmanaged(u8).empty;
        errdefer buffer.deinit(self.allocator);

        const shnum = 5; // Null, .text, .shstrtab, .symtab, .strtab
        const shstrndx = 2;

        // Calculate layout offsets
        const header_size = @sizeOf(Elf64Header);
        const code_offset = header_size;
        const code_size_aligned = (code.len + 15) & ~@as(usize, 15);
        const shstrtab_offset = code_offset + code_size_aligned;

        // Define section name table (.shstrtab)
        // 0: null, 1: .text, 7: .shstrtab, 17: .symtab, 25: .strtab
        const shstrtab_data = "\x00.text\x00.shstrtab\x00.symtab\x00.strtab\x00";
        const shstrtab_size_aligned = (shstrtab_data.len + 15) & ~@as(usize, 15);
        const symtab_offset = shstrtab_offset + shstrtab_size_aligned;

        // Define symbols table (.symtab)
        // Entry 0: Undefined
        // Entry 1: function name
        const syms = [_]Elf64Symbol{
            .{ .name = 0, .info = 0, .shndx = 0, .value = 0 },
            .{ .name = 1, .info = (1 << 4) | 2, .shndx = 1, .value = 0 }, // STB_GLOBAL | STT_FUNC
        };
        const symtab_size_aligned = (@sizeOf(Elf64Symbol) * syms.len + 15) & ~@as(usize, 15);
        const strtab_offset = symtab_offset + symtab_size_aligned;

        // Define string table (.strtab)
        // 0: null, 1: function_name
        var strtab = std.ArrayListUnmanaged(u8).empty;
        defer strtab.deinit(self.allocator);
        try strtab.append(self.allocator, 0);
        try strtab.appendSlice(self.allocator, func_name);
        try strtab.append(self.allocator, 0);
        const strtab_size_aligned = (strtab.items.len + 15) & ~@as(usize, 15);
        const sh_offset = strtab_offset + strtab_size_aligned;

        // Write ELF64 Header portably
        try writeHeader(&buffer, self.allocator, sh_offset, shnum, shstrndx);

        // Write Code section data
        const code_pad = code_size_aligned - code.len;
        try buffer.appendSlice(self.allocator, code);
        if (code_pad > 0) try buffer.appendNTimes(self.allocator, 0, code_pad);

        // Write .shstrtab section data
        try buffer.appendSlice(self.allocator, shstrtab_data);
        const shstrtab_pad = shstrtab_size_aligned - shstrtab_data.len;
        if (shstrtab_pad > 0) try buffer.appendNTimes(self.allocator, 0, shstrtab_pad);

        // Write .symtab section data
        for (syms) |sym| {
            try writeSymbol(&buffer, self.allocator, sym);
        }
        const symtab_pad = symtab_size_aligned - (@sizeOf(Elf64Symbol) * syms.len);
        if (symtab_pad > 0) try buffer.appendNTimes(self.allocator, 0, symtab_pad);

        // Write .strtab section data
        try buffer.appendSlice(self.allocator, strtab.items);
        const strtab_pad = strtab_size_aligned - strtab.items.len;
        if (strtab_pad > 0) try buffer.appendNTimes(self.allocator, 0, strtab_pad);

        // Write Section Headers
        // Section 0: NULL
        const sh_null = std.mem.zeroes(Elf64SectionHeader);
        try writeSectionHeader(&buffer, self.allocator, sh_null);

        // Section 1: .text (Code)
        const sh_text = Elf64SectionHeader{
            .name = 1,
            .type_field = 1, // SHT_PROGBITS
            .flags = 6, // SHF_ALLOC | SHF_EXECINSTR
            .offset = code_offset,
            .size = code.len,
            .addralign = 16,
        };
        try writeSectionHeader(&buffer, self.allocator, sh_text);

        // Section 2: .shstrtab (Section Names)
        const sh_shstrtab = Elf64SectionHeader{
            .name = 7,
            .type_field = 3, // SHT_STRTAB
            .flags = 0,
            .offset = shstrtab_offset,
            .size = shstrtab_data.len,
            .addralign = 1,
        };
        try writeSectionHeader(&buffer, self.allocator, sh_shstrtab);

        // Section 3: .symtab (Symbol Table)
        const sh_symtab = Elf64SectionHeader{
            .name = 17,
            .type_field = 2, // SHT_SYMTAB
            .flags = 0,
            .offset = symtab_offset,
            .size = @sizeOf(Elf64Symbol) * syms.len,
            .link = 4, // link to .strtab
            .info = 1, // index of first non-local symbol
            .addralign = 8,
            .entsize = @sizeOf(Elf64Symbol),
        };
        try writeSectionHeader(&buffer, self.allocator, sh_symtab);

        // Section 4: .strtab (Strings)
        const sh_strtab = Elf64SectionHeader{
            .name = 25,
            .type_field = 3, // SHT_STRTAB
            .flags = 0,
            .offset = strtab_offset,
            .size = strtab.items.len,
            .addralign = 1,
        };
        try writeSectionHeader(&buffer, self.allocator, sh_strtab);

        return try buffer.toOwnedSlice(self.allocator);
    }
};
