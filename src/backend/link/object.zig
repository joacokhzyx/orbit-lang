//! orbit/src/backend/link/object.zig
//!
//! Neutral object model representing sections, symbols, and relocations.
//! Pivot model for all writers, readers, and the linker.

const std = @import("std");

pub const SectionKind = enum {
    text,
    rodata,
    data,
    bss,
};

pub const SectionFlags = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
};

pub const RelocKind = enum {
    ABS64,
    PC32,
    PC32_PLT,
    ABS32,
    ABS32S,
    RVA32,
};

pub const Reloc = struct {
    offset_in_section: u64,
    target_symbol_index: u32,
    kind: RelocKind,
    addend: i64,
};

pub const Section = struct {
    name: []const u8,
    kind: SectionKind,
    flags: SectionFlags,
    alignment: u32,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    relocs: std.ArrayListUnmanaged(Reloc) = .empty,

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.bytes.deinit(allocator);
        self.relocs.deinit(allocator);
    }

    pub fn clone(self: Section, allocator: std.mem.Allocator) !Section {
        var copy = Section{
            .name = try allocator.dupe(u8, self.name),
            .kind = self.kind,
            .flags = self.flags,
            .alignment = self.alignment,
            .bytes = .empty,
            .relocs = .empty,
        };
        try copy.bytes.appendSlice(allocator, self.bytes.items);
        try copy.relocs.appendSlice(allocator, self.relocs.items);
        return copy;
    }
};

pub const SymbolBinding = enum {
    local,
    global,
    weak,
};

pub const SymbolKind = enum {
    func,
    object,
    notype,
};

pub const Symbol = struct {
    name: []const u8,
    section_index: ?u32, // null means UNDEF or ABS (based on is_abs)
    is_abs: bool = false,
    value: u64, // value/offset
    binding: SymbolBinding,
    kind: SymbolKind,
    is_defined: bool,
    is_extern: bool,
    dll_name: ?[]const u8 = null, // Set for DLL imports

    pub fn clone(self: Symbol, allocator: std.mem.Allocator) !Symbol {
        return Symbol{
            .name = try allocator.dupe(u8, self.name),
            .section_index = self.section_index,
            .is_abs = self.is_abs,
            .value = self.value,
            .binding = self.binding,
            .kind = self.kind,
            .is_defined = self.is_defined,
            .is_extern = self.is_extern,
            .dll_name = if (self.dll_name) |dn| try allocator.dupe(u8, dn) else null,
        };
    }
};

pub const Object = struct {
    sections: std.ArrayListUnmanaged(Section) = .empty,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,

    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        for (self.sections.items) |*sec| {
            sec.deinit(allocator);
        }
        self.sections.deinit(allocator);
        for (self.symbols.items) |sym| {
            allocator.free(sym.name);
            if (sym.dll_name) |dn| {
                allocator.free(dn);
            }
        }
        self.symbols.deinit(allocator);
    }
};
