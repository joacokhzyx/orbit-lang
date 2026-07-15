//! orbit/src/backend/link/elf_image.zig
//!
//! Generates System V ABI ELF-64 executable images from merged sections.

const std = @import("std");
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const layout = @import("layout.zig");

const PT_LOAD = 1;
const PF_X = 1;
const PF_W = 2;
const PF_R = 4;

const Elf64Header = extern struct {
    magic: [4]u8 = .{ 0x7F, 'E', 'L', 'F' },
    class: u8 = 2, // 64-bit
    data: u8 = 1, // Little endian
    version: u8 = 1,
    osabi: u8 = 0, // System V
    abiversion: u8 = 0,
    pad: [7]u8 = @splat(0),
    type_field: u16, // ET_EXEC
    machine: u16 = 0x3E, // x86-64
    version2: u32 = 1,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32 = 0,
    ehsize: u16 = @sizeOf(Elf64Header),
    phentsize: u16 = @sizeOf(Elf64Phdr),
    phnum: u16,
    shentsize: u16 = 0,
    shnum: u16 = 0,
    shstrndx: u16 = 0,
};

const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub fn writeExecutable(allocator: std.mem.Allocator, linker: *Linker, entry_name: []const u8) ![]const u8 {
    var out_bytes = std.ArrayList(u8).empty;
    defer out_bytes.deinit(allocator);

    // Assign ELF virtual addresses and file offsets
    const base_addr: u64 = 0x400000;
    const section_alignment: u32 = 0x1000;
    const file_alignment: u32 = 0x1000;
    const num_phdrs = 2;
    const header_size = @sizeOf(Elf64Header) + num_phdrs * @sizeOf(Elf64Phdr);

    linker.assignAddresses(base_addr, section_alignment, file_alignment, header_size);
    try linker.resolveSymbolAddresses();
    try linker.applyRelocations(base_addr);

    // Find entry point address (default to '_start' or 'main')
    const entry_addr = linker.symbol_addresses.get(entry_name) orelse blk: {
        if (linker.symbol_addresses.get("_start")) |addr| break :blk addr;
        if (linker.symbol_addresses.get("main")) |addr| break :blk addr;
        return error.EntrySymbolNotFound;
    };

    // We have 2 PT_LOAD segments:
    // 1. Text segment (R-X)
    // 2. Data segment (RW-) including .rodata, .data, .bss

    var text_sec: ?*const layout.MergedSection = null;
    var rodata_sec: ?*const layout.MergedSection = null;
    var data_sec: ?*const layout.MergedSection = null;
    var bss_sec: ?*const layout.MergedSection = null;

    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".text")) {
            text_sec = ms;
        } else if (std.mem.eql(u8, ms.name, ".rodata")) {
            rodata_sec = ms;
        } else if (std.mem.eql(u8, ms.name, ".data")) {
            data_sec = ms;
        } else if (std.mem.eql(u8, ms.name, ".bss")) {
            bss_sec = ms;
        }
    }

    if (text_sec == null) return error.MissingTextSection;

    // Write placeholder for headers
    try out_bytes.appendNTimes(allocator, 0, header_size);

    // Text segment (R-X)
    // Maps from 0 in file to cover the ELF headers and .text section
    const text_filesz = text_sec.?.file_offset + text_sec.?.size;
    const text_memsz = text_filesz;

    const ph_text = Elf64Phdr{
        .p_type = PT_LOAD,
        .p_flags = PF_R | PF_X,
        .p_offset = 0,
        .p_vaddr = base_addr,
        .p_paddr = base_addr,
        .p_filesz = text_filesz,
        .p_memsz = text_memsz,
        .p_align = 0x1000,
    };

    // Data segment (RW-)
    // We group .rodata, .data, .bss into the second loadable segment.
    var data_offset: u64 = 0;
    var data_vaddr: u64 = 0;
    var data_filesz: u64 = 0;
    var data_memsz: u64 = 0;

    if (rodata_sec) |ro| {
        data_offset = ro.file_offset;
        data_vaddr = ro.virtual_address;
    } else if (data_sec) |d| {
        data_offset = d.file_offset;
        data_vaddr = d.virtual_address;
    } else if (bss_sec) |b| {
        data_offset = b.file_offset;
        data_vaddr = b.virtual_address;
    }

    if (data_offset > 0) {
        var max_file_end: u64 = data_offset;
        var max_mem_end: u64 = data_vaddr;

        if (rodata_sec) |ro| {
            max_file_end = @max(max_file_end, ro.file_offset + ro.size);
            max_mem_end = @max(max_mem_end, ro.virtual_address + ro.size);
        }
        if (data_sec) |d| {
            max_file_end = @max(max_file_end, d.file_offset + d.size);
            max_mem_end = @max(max_mem_end, d.virtual_address + d.size);
        }
        if (bss_sec) |b| {
            max_mem_end = @max(max_mem_end, b.virtual_address + b.size);
        }

        data_filesz = max_file_end - data_offset;
        data_memsz = max_mem_end - data_vaddr;
    }

    const ph_data = Elf64Phdr{
        .p_type = PT_LOAD,
        .p_flags = PF_R | PF_W,
        .p_offset = data_offset,
        .p_vaddr = data_vaddr,
        .p_paddr = data_vaddr,
        .p_filesz = data_filesz,
        .p_memsz = data_memsz,
        .p_align = 0x1000,
    };

    // Fill in section data in the output byte array
    for (linker.merged_sections.items) |ms| {
        if (ms.kind == .bss) continue;

        // Align output file offset
        if (out_bytes.items.len < ms.file_offset) {
            try out_bytes.appendNTimes(allocator, 0, @intCast(ms.file_offset - out_bytes.items.len));
        }
        try out_bytes.appendSlice(allocator, ms.bytes.items);
    }

    // Write Elf64 Header
    const hdr = Elf64Header{
        .type_field = 2, // ET_EXEC
        .entry = entry_addr,
        .phoff = @sizeOf(Elf64Header),
        .shoff = 0, // Section headers are optional for executable execution
        .phnum = num_phdrs,
        .shstrndx = 0,
    };
    @memcpy(out_bytes.items[0..@sizeOf(Elf64Header)], std.mem.asBytes(&hdr));

    // Write Program Headers
    const ph1_offset = @sizeOf(Elf64Header);
    const ph2_offset = ph1_offset + @sizeOf(Elf64Phdr);
    @memcpy(out_bytes.items[ph1_offset .. ph1_offset + @sizeOf(Elf64Phdr)], std.mem.asBytes(&ph_text));
    @memcpy(out_bytes.items[ph2_offset .. ph2_offset + @sizeOf(Elf64Phdr)], std.mem.asBytes(&ph_data));

    return out_bytes.toOwnedSlice(allocator);
}
