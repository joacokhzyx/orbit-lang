//! orbit/src/backend/link/linker.zig
//!
//! Neutral object linker engine: merges sections, resolves symbol bindings,
//! manages lazy archive loading, and patches relocation points.

const std = @import("std");
const object = @import("object.zig");
const Object = object.Object;
const Symbol = object.Symbol;
const reloc_math = @import("reloc.zig");
const archive = @import("archive.zig");
const Archive = archive.Archive;
const layout = @import("layout.zig");
const MergedSection = layout.MergedSection;
const SectionLayoutMap = layout.SectionLayoutMap;

pub const LoadedObject = struct {
    name: []const u8,
    obj: Object,
};

pub const ArchiveMemberKey = struct {
    arch_idx: u32,
    member_idx: u32,
};

fn isStandardWin32Symbol(name: []const u8) bool {
    const std_symbols = [_][]const u8{
        // memory / crt
        "malloc", "free", "realloc", "calloc", "memset", "memcpy", "strlen", "strcmp", "strcpy", "exit", "abort",
        "printf", "fprintf", "sprintf", "snprintf", "fclose", "fopen", "fread", "fwrite", "fseek", "ftell", "fgets",
        "getenv", "readdir", "opendir", "closedir", "sscanf", "strtol", "strtod", "_popen", "_pclose",
        // compiler intrinsics
        "__main", "@feat.00", ".file", "__stack_chk_fail", "__stack_chk_guard",
        "__ubsan_handle_nonnull_arg", "__ubsan_handle_pointer_overflow", "__ubsan_handle_type_mismatch_v1",
        "__ubsan_handle_builtin_unreachable", "__ubsan_handle_load_invalid_value", "__ubsan_handle_add_overflow",
        "___chkstk_ms", "__chkstk", "__chkstk_ms",
        // ws2_32
        "WSAStartup", "WSACleanup", "socket", "connect", "send", "recv", "closesocket", "htons", "setsockopt", "bind", "listen", "accept", "select", "__WSAFDIsSet", "getaddrinfo", "freeaddrinfo",
        // kernel32
        "ExitProcess", "GetStdHandle", "WriteFile", "ReadFile", "CreateFileA", "CloseHandle", "GetLastError", "Sleep", "GetSystemTime", "GetTimeZoneInformation", "GetSystemInfo", "VirtualAlloc", "VirtualFree", "IsDebuggerPresent", "CheckRemoteDebuggerPresent", "GetCurrentProcess",
        "FindFirstFileA", "FindNextFileA", "FindClose",
    };
    for (std_symbols) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

pub const Linker = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(LoadedObject) = .empty,
    archives: std.ArrayListUnmanaged(Archive) = .empty,
    merged_sections: std.ArrayListUnmanaged(MergedSection) = .empty,
    layout_map: SectionLayoutMap = .{},
    // Global resolved symbol address map
    symbol_addresses: std.StringHashMap(u64),
    // Track which archive members were pulled
    pulled_archive_members: std.AutoHashMap(ArchiveMemberKey, void),
    // Track allocated keys to avoid use-after-free
    allocated_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    base_relocs: std.ArrayListUnmanaged(BaseReloc) = .empty,

    pub const BaseReloc = struct {
        rva: u32,
        type: u8,
    };

    pub fn init(allocator: std.mem.Allocator) Linker {
        return .{
            .allocator = allocator,
            .symbol_addresses = std.StringHashMap(u64).init(allocator),
            .pulled_archive_members = std.AutoHashMap(ArchiveMemberKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *Linker) void {
        for (self.objects.items) |*lo| {
            self.allocator.free(lo.name);
            lo.obj.deinit(self.allocator);
        }
        self.objects.deinit(self.allocator);

        for (self.archives.items) |*ar| {
            ar.deinit();
        }
        self.archives.deinit(self.allocator);

        for (self.merged_sections.items) |*ms| {
            ms.deinit(self.allocator);
        }
        self.merged_sections.deinit(self.allocator);
        self.layout_map.deinit(self.allocator);
        self.symbol_addresses.deinit();
        self.pulled_archive_members.deinit();
        self.base_relocs.deinit(self.allocator);

        for (self.allocated_keys.items) |k| {
            self.allocator.free(k);
        }
        self.allocated_keys.deinit(self.allocator);
    }

    pub fn addObject(self: *Linker, name: []const u8, obj: Object) !void {
        try self.objects.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .obj = obj,
        });
    }

    pub fn addArchive(self: *Linker, ar: Archive) !void {
        try self.archives.append(self.allocator, ar);
    }

    /// Resolves all symbols, pulling archive members as needed.
    pub fn resolveSymbols(self: *Linker) !void {
        var undefined_symbols = std.StringHashMap(void).init(self.allocator);
        defer undefined_symbols.deinit();

        var defined_symbols = std.StringHashMap(struct { obj_name: []const u8, is_weak: bool }).init(self.allocator);
        defer defined_symbols.deinit();

        // Loop until fixed point: no new archive members are pulled
        while (true) {
            undefined_symbols.clearRetainingCapacity();
            defined_symbols.clearRetainingCapacity();

            // 1. Gather all defined and undefined symbols from loaded objects
            for (self.objects.items) |lo| {
                for (lo.obj.symbols.items) |sym| {
                    if (sym.name.len == 0) continue;
                    if (sym.is_defined) {
                        if (defined_symbols.get(sym.name)) |existing| {
                            if (sym.binding != .local and !existing.is_weak and sym.binding != .weak) {
                                // Double definition of strong symbols is a linker error!
                                std.debug.print("Linker error: duplicate symbol '{s}' in {s} and {s}\n", .{ sym.name, existing.obj_name, lo.name });
                                return error.DuplicateSymbol;
                            }
                        }
                        if (sym.binding != .local) {
                            try defined_symbols.put(sym.name, .{
                                .obj_name = lo.name,
                                .is_weak = sym.binding == .weak,
                            });
                        }
                    } else {
                        if (sym.binding != .weak) {
                            try undefined_symbols.put(sym.name, {});
                        }
                    }
                }
            }

            // Remove defined symbols from undefined set
            var it = undefined_symbols.keyIterator();
            var new_pulls = false;
            while (it.next()) |key| {
                const name = key.*;
                if (defined_symbols.contains(name)) continue;

                // Try to resolve from static archives
                for (self.archives.items, 0..) |ar, ar_idx| {
                    if (ar.symbol_to_member.get(name)) |member_idx| {
                        const key_pair = ArchiveMemberKey{ .arch_idx = @as(u32, @intCast(ar_idx)), .member_idx = member_idx };
                        if (self.pulled_archive_members.contains(key_pair)) continue;

                        try self.pulled_archive_members.put(key_pair, {});

                        const member = ar.members.items[member_idx];
                        // Parse member bytes to Object
                        var obj: Object = undefined;
                        const is_short_import = member.data.len >= 20 and member.data[0] == 0 and member.data[1] == 0 and member.data[2] == 0xFF and member.data[3] == 0xFF;
                        if (is_short_import) {
                            const sym_name = std.mem.span(@as([*:0]const u8, @ptrCast(&member.data[20])));
                            const dll_name = std.mem.span(@as([*:0]const u8, @ptrCast(&member.data[20 + sym_name.len + 1])));

                            obj = Object{};
                            // Add sym_name symbol
                            try obj.symbols.append(self.allocator, Symbol{
                                .name = try self.allocator.dupe(u8, sym_name),
                                .section_index = null,
                                .is_abs = true,
                                .value = 0,
                                .binding = .global,
                                .kind = .func,
                                .is_defined = true,
                                .is_extern = false,
                                .dll_name = try self.allocator.dupe(u8, dll_name),
                            });
                            // Add __imp_sym_name symbol
                            const imp_name = try std.fmt.allocPrint(self.allocator, "__imp_{s}", .{sym_name});
                            try obj.symbols.append(self.allocator, Symbol{
                                .name = imp_name,
                                .section_index = null,
                                .is_abs = true,
                                .value = 0,
                                .binding = .global,
                                .kind = .object,
                                .is_defined = true,
                                .is_extern = false,
                                .dll_name = try self.allocator.dupe(u8, dll_name),
                            });
                        } else if (std.mem.eql(u8, member.data[0..4], "\x7fELF")) {
                            obj = try @import("elf_reader.zig").readObject(self.allocator, member.data);
                        } else {
                            obj = try @import("coff_reader.zig").readObject(self.allocator, member.data);
                        }
                        try self.addObject(member.name, obj);
                        new_pulls = true;
                        break;
                    }
                }
                if (new_pulls) break;
            }

            if (!new_pulls) {
                // Verify all undefined symbols are resolved
                const builtin = @import("builtin");
                var unresolved_it = undefined_symbols.keyIterator();
                var has_unresolved = false;
                while (unresolved_it.next()) |key| {
                    const name = key.*;
                    if (!defined_symbols.contains(name)) {
                        if (builtin.os.tag == .windows) {
                            var clean_name = name;
                            if (std.mem.startsWith(u8, clean_name, "__imp_")) {
                                clean_name = clean_name["__imp_".len..];
                            }
                            if (isStandardWin32Symbol(clean_name)) {
                                continue;
                            }
                        }
                        // Some compiler runtime symbols (like __chkstk, memset, etc.) are standard,
                        // if they are not defined, output an error.
                        std.debug.print("Linker error: undefined symbol '{s}'\n", .{name});
                        has_unresolved = true;
                    }
                }
                if (has_unresolved) return error.UndefinedSymbol;
                break;
            }
        }
    }

    /// Merges section lists of all loaded objects.
    pub fn mergeSections(self: *Linker) !void {
        for (self.objects.items, 0..) |lo, obj_idx| {
            for (lo.obj.sections.items, 0..) |sec, sec_idx| {
                // Find existing merged section with the same name
                var found_idx: ?usize = null;
                for (self.merged_sections.items, 0..) |ms, ms_idx| {
                    if (std.mem.eql(u8, ms.name, sec.name)) {
                        found_idx = ms_idx;
                        break;
                    }
                }

                if (found_idx == null) {
                    try self.merged_sections.append(self.allocator, MergedSection{
                        .name = try self.allocator.dupe(u8, sec.name),
                        .kind = sec.kind,
                        .flags = sec.flags,
                        .alignment = sec.alignment,
                    });
                    found_idx = self.merged_sections.items.len - 1;
                }

                var ms = &self.merged_sections.items[found_idx.?];
                ms.alignment = @max(ms.alignment, sec.alignment);

                // Align current section size
                const offset = layout.alignTo(ms.bytes.items.len, sec.alignment);
                const pad = offset - ms.bytes.items.len;
                if (pad > 0) {
                    try ms.bytes.appendNTimes(self.allocator, 0, @intCast(pad));
                }

                try self.layout_map.put(self.allocator, @intCast(obj_idx), @intCast(sec_idx), offset);
                try ms.bytes.appendSlice(self.allocator, sec.bytes.items);
                ms.size = ms.bytes.items.len;
            }
        }
    }

    /// Assign virtual addresses and file offsets (used by PE/ELF writers).
    pub fn assignAddresses(self: *Linker, base_addr: u64, section_alignment: u32, file_alignment: u32, header_size: u64) void {
        var current_va = base_addr + header_size;
        var current_file_off = header_size;

        for (self.merged_sections.items) |*ms| {
            current_va = layout.alignTo(current_va, section_alignment);
            current_file_off = layout.alignTo(current_file_off, file_alignment);

            ms.virtual_address = current_va;
            ms.file_offset = current_file_off;

            // Ensure distinct, non-overlapping virtual address space for each section
            const aligned_vsize = layout.alignTo(if (ms.size == 0) 1 else ms.size, section_alignment);
            current_va += aligned_vsize;

            // Raw data on disk is only present for non-BSS sections with non-zero size
            const file_sz = if (ms.kind == .bss) 0 else layout.alignTo(ms.size, file_alignment);
            current_file_off += file_sz;
        }
    }

    /// Resolves absolute address of all symbols.
    pub fn resolveSymbolAddresses(self: *Linker) !void {
        // First resolve local symbols (which are object-specific)
        // and resolve global symbols (which can be looked up by name)
        for (self.objects.items, 0..) |lo, obj_idx| {
            for (lo.obj.symbols.items, 0..) |sym, sym_idx| {
                var addr: u64 = 0;
                if (sym.section_index) |sec_idx| {
                    const sec_name = lo.obj.sections.items[sec_idx].name;
                    // Find merged section
                    for (self.merged_sections.items) |ms| {
                        if (std.mem.eql(u8, ms.name, sec_name)) {
                            const offset = self.layout_map.get(@intCast(obj_idx), @intCast(sec_idx)).?;
                            addr = ms.virtual_address + offset + sym.value;
                            break;
                        }
                    }
                } else if (sym.is_abs) {
                    addr = sym.value;
                } else {
                    continue; // Undefined symbol
                }

                if (sym.binding == .local) {
                    // Local symbols resolved in object context
                    const key = try std.fmt.allocPrint(self.allocator, "{d}_{d}", .{ obj_idx, sym_idx });
                    try self.allocated_keys.append(self.allocator, key);
                    try self.symbol_addresses.put(key, addr);
                    if (addr == 0) {
                        std.debug.print("[sym-debug] Local symbol {d}_{d} has addr=0! name='{s}' section_index={?} is_abs={}\n", .{ obj_idx, sym_idx, sym.name, sym.section_index, sym.is_abs });
                    }
                } else {
                    // Global symbols resolved globally by name
                    // Strong symbols overwrite weak symbols
                    if (self.symbol_addresses.get(sym.name)) |_| {
                        if (sym.binding != .weak) {
                            try self.symbol_addresses.put(sym.name, addr);
                        }
                    } else {
                        try self.symbol_addresses.put(sym.name, addr);
                    }
                }
            }
        }
    }

    pub fn getSymbolAddress(self: Linker, obj_idx: u32, sym_idx: u32) u64 {
        const obj = &self.objects.items[obj_idx];
        const sym = &obj.obj.symbols.items[sym_idx];

        if (sym.binding == .local) {
            var buf: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}_{d}", .{ obj_idx, sym_idx }) catch unreachable;
            return self.symbol_addresses.get(key) orelse 0;
        } else {
            return self.symbol_addresses.get(sym.name) orelse 0;
        }
    }

    /// Applies relocations in merged sections.
    pub fn applyRelocations(self: *Linker, image_base: u64) !void {
        for (self.objects.items, 0..) |lo, obj_idx| {
            for (lo.obj.sections.items, 0..) |sec, sec_idx| {
                // Find merged section
                var ms_opt: ?*MergedSection = null;
                for (self.merged_sections.items) |*ms| {
                    if (std.mem.eql(u8, ms.name, sec.name)) {
                        ms_opt = ms;
                        break;
                    }
                }
                if (ms_opt == null) continue;
                const ms = ms_opt.?;
                const sec_offset = self.layout_map.get(@intCast(obj_idx), @intCast(sec_idx)).?;

                for (sec.relocs.items) |rel| {
                    const S = self.getSymbolAddress(@intCast(obj_idx), rel.target_symbol_index);
                    const A = rel.addend;
                    const patch_offset = sec_offset + rel.offset_in_section;
                    const P = ms.virtual_address + patch_offset;

                    const sym = lo.obj.symbols.items[rel.target_symbol_index];
                    const patch_slice = ms.bytes.items[patch_offset..];
                    reloc_math.applyReloc(rel.kind, patch_slice, S, A, P, image_base) catch |err| {
                        std.debug.print("[reloc-error] Symbol '{s}' kind={s} S=0x{x} A={d} P=0x{x} image_base=0x{x}\n", .{ sym.name, @tagName(rel.kind), S, A, P, image_base });
                        return err;
                    };

                    if (rel.kind == .ABS64) {
                        try self.base_relocs.append(self.allocator, .{
                            .rva = @intCast(P - image_base),
                            .type = 10, // IMAGE_REL_BASED_DIR64
                        });
                    }
                }
            }
        }
    }
};
