//! orbit/src/backend/link/pe_image.zig
//!
//! Generates the final PE64 (.exe) executable image from merged sections and resolved symbols.

const std = @import("std");
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const layout = @import("layout.zig");
const MergedSection = layout.MergedSection;

fn ArrayList(comptime T: type) type {
    return struct {
        const Self = @This();
        unmanaged: std.ArrayListUnmanaged(T) = .empty,
        allocator: std.mem.Allocator,
        items: []T = &.{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn append(self: *Self, item: T) !void {
            try self.unmanaged.append(self.allocator, item);
            self.items = self.unmanaged.items;
        }

        pub fn appendSlice(self: *Self, items: []const T) !void {
            try self.unmanaged.appendSlice(self.allocator, items);
            self.items = self.unmanaged.items;
        }

        pub fn appendNTimes(self: *Self, item: T, n: usize) !void {
            try self.unmanaged.appendNTimes(self.allocator, item, n);
            self.items = self.unmanaged.items;
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            const res = try self.unmanaged.toOwnedSlice(self.allocator);
            self.items = &.{};
            return res;
        }
    };
}

pub const IMAGE_IMPORT_DESCRIPTOR = extern struct {
    ImportLookupTableRVA: u32,
    TimeDateStamp: u32 = 0,
    ForwarderChain: u32 = 0,
    NameRVA: u32,
    ImportAddressTableRVA: u32,
};

pub const IMAGE_SECTION_HEADER = extern struct {
    Name: [8]u8,
    VirtualSize: u32,
    VirtualAddress: u32,
    SizeOfRawData: u32,
    PointerToRawData: u32,
    PointerToRelocations: u32 = 0,
    PointerToLinenumbers: u32 = 0,
    NumberOfRelocations: u16 = 0,
    NumberOfLinenumbers: u16 = 0,
    Characteristics: u32,
};

pub fn writeExecutable(allocator: std.mem.Allocator, linker: *Linker, entry_name: []const u8) ![]const u8 {
    // 1. Gather all DLL imports
    const DllImport = struct {
        name: []const u8,
        dll_name: []const u8,
        sym_name: []const u8, // without __imp_ prefix if any
        is_imp_only: bool,
    };

    var imports = ArrayList(DllImport).init(allocator);
    defer imports.deinit();

    var allocated_strings = ArrayList([]const u8).init(allocator);
    defer {
        for (allocated_strings.items) |s| {
            allocator.free(s);
        }
        allocated_strings.deinit();
    }

    for (linker.objects.items) |lo| {
        for (lo.obj.symbols.items) |sym| {
            if (sym.name.len == 0) continue;
            const name = sym.name;
            var sym_name_clean = name;
            if (std.mem.startsWith(u8, name, "__imp_")) {
                sym_name_clean = name["__imp_".len..];
            }

            if (sym.is_abs) continue;
            if (std.mem.startsWith(u8, sym_name_clean, "@") or std.mem.startsWith(u8, sym_name_clean, ".")) continue;

            var is_defined_in_objs = false;
            var dll_name_opt = sym.dll_name;

            for (linker.objects.items) |o2| {
                for (o2.obj.symbols.items) |s2| {
                    if (std.mem.eql(u8, s2.name, name) or std.mem.eql(u8, s2.name, sym_name_clean)) {
                        if (s2.is_defined and !std.mem.startsWith(u8, s2.name, "__imp_")) {
                            is_defined_in_objs = true;
                        }
                        if (s2.dll_name) |dn| {
                            dll_name_opt = dn;
                        }
                    }
                }
            }

            if (is_defined_in_objs and !std.mem.startsWith(u8, name, "__imp_")) continue;

            if (dll_name_opt == null) {
                const name_clean = sym_name_clean;
                // Compiler intrinsics / sanitizer handlers / POSIX symbols that do NOT
                // exist in any standard Windows import DLL. Skip them so the import
                // table does not reference a function that cannot be resolved at load time.
                const blocklist = [_][]const u8{
                    "__stack_chk_fail", "__stack_chk_guard",
                    "__ubsan_handle_nonnull_arg", "__ubsan_handle_pointer_overflow",
                    "__ubsan_handle_type_mismatch_v1", "__ubsan_handle_builtin_unreachable",
                    "__ubsan_handle_load_invalid_value", "__ubsan_handle_add_overflow",
                    "__ubsan_handle_sub_overflow", "__ubsan_handle_mul_overflow",
                    "__ubsan_handle_divrem_overflow", "__ubsan_handle_shift_out_of_bounds",
                    "__ubsan_handle_out_of_bounds", "__ubsan_handle_missing_return",
                    "opendir", "readdir", "closedir", "scandir",
                    "__main",
                    // Stack-probe intrinsics: provided internally by the compiler runtime,
                    // not by any import DLL.
                    "___chkstk_ms", "__chkstk", "__chkstk_ms",
                };
                var blocked = false;
                for (blocklist) |bl| {
                    if (std.mem.eql(u8, name_clean, bl)) {
                        blocked = true;
                        break;
                    }
                }
                if (blocked) continue;

                if (std.mem.eql(u8, name_clean, "WSAStartup") or
                    std.mem.eql(u8, name_clean, "WSACleanup") or
                    std.mem.eql(u8, name_clean, "socket") or
                    std.mem.eql(u8, name_clean, "connect") or
                    std.mem.eql(u8, name_clean, "send") or
                    std.mem.eql(u8, name_clean, "recv") or
                    std.mem.eql(u8, name_clean, "closesocket") or
                    std.mem.eql(u8, name_clean, "htons") or
                    std.mem.eql(u8, name_clean, "setsockopt") or
                    std.mem.eql(u8, name_clean, "bind") or
                    std.mem.eql(u8, name_clean, "listen") or
                    std.mem.eql(u8, name_clean, "accept") or
                    std.mem.eql(u8, name_clean, "select") or
                    std.mem.eql(u8, name_clean, "__WSAFDIsSet") or
                    std.mem.eql(u8, name_clean, "getaddrinfo") or
                    std.mem.eql(u8, name_clean, "freeaddrinfo")) {
                    dll_name_opt = "ws2_32.dll";
                } else if (name_clean[0] >= 'A' and name_clean[0] <= 'Z') {
                    dll_name_opt = "kernel32.dll";
                } else {
                    dll_name_opt = "msvcrt.dll";
                }
            }

            if (dll_name_opt) |dll_name| {
                // Check if we already added this symbol
                var exists = false;
                for (imports.items) |imp| {
                    if (std.mem.eql(u8, imp.sym_name, sym_name_clean)) {
                        exists = true;
                        break;
                    }
                }

                if (!exists) {
                    try imports.append(.{
                        .name = name,
                        .dll_name = dll_name,
                        .sym_name = try allocator.dupe(u8, sym_name_clean),
                        .is_imp_only = std.mem.startsWith(u8, name, "__imp_"),
                    });
                }
            }
        }
    }

    // Group imports by DLL
    var dll_groups = std.StringHashMap(ArrayList(DllImport)).init(allocator);
    defer {
        var git = dll_groups.iterator();
        while (git.next()) |entry| {
            entry.value_ptr.deinit();
        }
        dll_groups.deinit();
    }

    for (imports.items) |imp| {
        var g_res = try dll_groups.getOrPut(imp.dll_name);
        if (!g_res.found_existing) {
            g_res.value_ptr.* = ArrayList(DllImport).init(allocator);
        }
        try g_res.value_ptr.append(imp);
    }

    // 2. Build .idata section layout if we have imports
    var idata_bytes = ArrayList(u8).init(allocator);
    defer idata_bytes.deinit();

    var iat_slot_offsets = std.StringHashMap(u64).init(allocator);
    defer iat_slot_offsets.deinit();

    var iat_start_offset: u32 = 0;
    var iat_total_size: u32 = 0;

    if (dll_groups.count() > 0) {
        var dlls_list = ArrayList([]const u8).init(allocator);
        defer dlls_list.deinit();
        var git = dll_groups.keyIterator();
        while (git.next()) |k| try dlls_list.append(k.*);

        // Sort DLL names for reproducibility
        std.mem.sort([]const u8, dlls_list.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);

        const num_dlls = dlls_list.items.len;
        const import_dir_size = (num_dlls + 1) * @sizeOf(IMAGE_IMPORT_DESCRIPTOR);
        try idata_bytes.appendNTimes(0, import_dir_size);

        // We will assign offsets sequentially in idata_bytes
        // Setup ILTs, IATs, DLL names, Hin/Name strings
        var ilt_offsets = try allocator.alloc(u64, num_dlls);
        defer allocator.free(ilt_offsets);
        var iat_offsets = try allocator.alloc(u64, num_dlls);
        defer allocator.free(iat_offsets);
        var dll_name_offsets = try allocator.alloc(u64, num_dlls);
        defer allocator.free(dll_name_offsets);

        // Build ILTs
        for (dlls_list.items, 0..) |dll, i| {
            const list = dll_groups.get(dll).?;
            ilt_offsets[i] = idata_bytes.items.len;
            try idata_bytes.appendNTimes(0, (list.items.len + 1) * 8);
        }

        // Build IATs in a contiguous block
        iat_start_offset = @intCast(idata_bytes.items.len);
        for (dlls_list.items, 0..) |dll, i| {
            const list = dll_groups.get(dll).?;
            iat_offsets[i] = idata_bytes.items.len;
            try idata_bytes.appendNTimes(0, (list.items.len + 1) * 8);
        }
        iat_total_size = @intCast(idata_bytes.items.len - iat_start_offset);

        // Build DLL Name strings
        for (dlls_list.items, 0..) |dll, i| {
            dll_name_offsets[i] = idata_bytes.items.len;
            try idata_bytes.appendSlice(dll);
            try idata_bytes.append(0);
        }

        // Build Hint/Name strings
        for (dlls_list.items, 0..) |dll, i| {
            const list = dll_groups.get(dll).?;
            for (list.items, 0..) |imp, func_idx| {
                const hn_offset = idata_bytes.items.len;
                // Hint (u16)
                try idata_bytes.appendSlice(&.{ 0, 0 });
                try idata_bytes.appendSlice(imp.sym_name);
                try idata_bytes.append(0);
                if (idata_bytes.items.len % 2 != 0) {
                    try idata_bytes.append(0); // padding
                }

                // Write ILT and IAT entries (initially pointing to Hint/Name RVA)
                const ilt_entry_offset = ilt_offsets[i] + func_idx * 8;
                std.mem.writeInt(u64, idata_bytes.items[ilt_entry_offset..][0..8], hn_offset, .little);

                const iat_entry_offset = iat_offsets[i] + func_idx * 8;
                std.mem.writeInt(u64, idata_bytes.items[iat_entry_offset..][0..8], hn_offset, .little);

                // Save IAT slot offset
                const imp_name = try std.fmt.allocPrint(allocator, "__imp_{s}", .{imp.sym_name});
                try allocated_strings.append(imp_name);
                try iat_slot_offsets.put(imp_name, iat_entry_offset);
            }
        }

        // Fill Import Directory Table
        for (dlls_list.items, 0..) |_, i| {
            const desc = IMAGE_IMPORT_DESCRIPTOR{
                .ImportLookupTableRVA = @intCast(ilt_offsets[i]),
                .NameRVA = @intCast(dll_name_offsets[i]),
                .ImportAddressTableRVA = @intCast(iat_offsets[i]),
            };
            const desc_bytes = std.mem.asBytes(&desc);
            const offset = i * @sizeOf(IMAGE_IMPORT_DESCRIPTOR);
            @memcpy(idata_bytes.items[offset .. offset + @sizeOf(IMAGE_IMPORT_DESCRIPTOR)], desc_bytes);
        }
    }

    // 3. Create .idata MergedSection and add it
    if (idata_bytes.items.len > 0) {
        var ms = MergedSection{
            .name = try allocator.dupe(u8, ".idata"),
            .kind = .rodata,
            .flags = .{ .read = true, .write = true, .execute = false },
            .alignment = 8,
        };
        try ms.bytes.appendSlice(allocator, idata_bytes.items);
        ms.size = ms.bytes.items.len;
        try linker.merged_sections.append(allocator, ms);
    }

    // 4. Generate jump stubs in `.text` for direct imports (if referenced directly)
    var text_sec: ?*MergedSection = null;
    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".text")) {
            text_sec = ms;
            break;
        }
    }

    if (text_sec == null) return error.MissingTextSection;

    // Track offset of each jump stub in .text
    const JumpStub = struct {
        sym_name: []const u8,
        stub_offset: u64,
    };
    var jump_stubs = ArrayList(JumpStub).init(allocator);
    defer jump_stubs.deinit();

    for (imports.items) |imp| {
        // If the direct symbol is referenced in some relocations
        var is_referenced = false;
        for (linker.objects.items) |lo| {
            for (lo.obj.sections.items) |sec| {
                for (sec.relocs.items) |rel| {
                    if (rel.target_symbol_index >= lo.obj.symbols.items.len) {
                        std.debug.print("[panic-debug] Object '{s}' section '{s}' reloc_offset={d} target_symbol_index={d} symbols.len={d}\n", .{ lo.name, sec.name, rel.offset_in_section, rel.target_symbol_index, lo.obj.symbols.items.len });
                    }
                    const target_sym = lo.obj.symbols.items[rel.target_symbol_index];
                    if (std.mem.eql(u8, target_sym.name, imp.sym_name)) {
                        is_referenced = true;
                        break;
                    }
                }
                if (is_referenced) break;
            }
            if (is_referenced) break;
        }

        if (is_referenced) {
            // Append jump stub to .text: jmp qword ptr [__imp_sym_name]
            // Instruction: FF 25 <32-bit displacement>
            // We append 6 bytes of placeholder
            const stub_offset = text_sec.?.bytes.items.len;
            try text_sec.?.bytes.appendSlice(allocator, &.{ 0xFF, 0x25, 0, 0, 0, 0 });
            text_sec.?.size = text_sec.?.bytes.items.len;

            try jump_stubs.append(.{
                .sym_name = imp.sym_name,
                .stub_offset = stub_offset,
            });
        }
    }

    // 4b. Inject compiler-intrinsic stubs for symbols that are referenced but
    //     cannot be satisfied by any Windows import DLL (e.g. ___chkstk_ms).
    //     We emit a minimal `ret` (0xC3) stub so relocations can resolve correctly.
    const IntrinsicStub = struct {
        sym_name: []const u8,
        stub_offset: u64,
    };
    var intrinsic_stub_list = std.ArrayListUnmanaged(IntrinsicStub).empty;
    defer intrinsic_stub_list.deinit(allocator);

    const intrinsic_names = [_][]const u8{
        "___chkstk_ms", "__chkstk", "__chkstk_ms",
    };
    for (intrinsic_names) |sym_name| {
        var is_referenced = false;
        var is_defined = false;
        for (linker.objects.items) |lo| {
            for (lo.obj.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, sym_name)) {
                    if (sym.is_defined) is_defined = true else is_referenced = true;
                }
            }
        }
        if (is_referenced and !is_defined) {
            const stub_offset = text_sec.?.bytes.items.len;
            // x86-64: push rax  (50), xor eax,eax (31 C0), ret (C3) — safe no-op stack probe
            try text_sec.?.bytes.appendSlice(allocator, &.{ 0x50, 0x31, 0xC0, 0x58, 0xC3, 0x90, 0x90, 0x90 });
            text_sec.?.size = text_sec.?.bytes.items.len;
            try intrinsic_stub_list.append(allocator, .{
                .sym_name = try allocator.dupe(u8, sym_name),
                .stub_offset = stub_offset,
            });
        }
    }

    // Pre-calculate base relocations size and add .reloc section
    const PreReloc = struct {
        ms_name: []const u8,
        offset: u32,
    };
    var pre_relocs = ArrayList(PreReloc).init(allocator);
    defer pre_relocs.deinit();

    for (linker.objects.items, 0..) |lo, obj_idx| {
        for (lo.obj.sections.items, 0..) |sec, sec_idx| {
            var ms_opt: ?*MergedSection = null;
            for (linker.merged_sections.items) |*ms| {
                if (std.mem.eql(u8, ms.name, sec.name)) {
                    ms_opt = ms;
                    break;
                }
            }
            if (ms_opt == null) continue;
            const ms = ms_opt.?;
            const sec_offset = linker.layout_map.get(@intCast(obj_idx), @intCast(sec_idx)).?;

            for (sec.relocs.items) |rel| {
                if (rel.kind == .ABS64) {
                    const patch_offset = sec_offset + rel.offset_in_section;
                    try pre_relocs.append(.{
                        .ms_name = ms.name,
                        .offset = @intCast(patch_offset),
                    });
                }
            }
        }
    }

    std.mem.sort(PreReloc, pre_relocs.items, {}, struct {
        fn lessThan(_: void, a: PreReloc, b: PreReloc) bool {
            if (std.mem.eql(u8, a.ms_name, b.ms_name)) {
                return a.offset < b.offset;
            }
            return std.mem.lessThan(u8, a.ms_name, b.ms_name);
        }
    }.lessThan);

    var reloc_bytes = ArrayList(u8).init(allocator);
    defer reloc_bytes.deinit();

    var pre_idx: usize = 0;
    while (pre_idx < pre_relocs.items.len) {
        const ms_name = pre_relocs.items[pre_idx].ms_name;
        const page_offset = pre_relocs.items[pre_idx].offset & 0xFFFFF000;

        var count: usize = 0;
        while (pre_idx + count < pre_relocs.items.len and
               std.mem.eql(u8, pre_relocs.items[pre_idx + count].ms_name, ms_name) and
               (pre_relocs.items[pre_idx + count].offset & 0xFFFFF000) == page_offset) {
            count += 1;
        }

        const has_padding = (count % 2 != 0);
        const num_entries = count + (if (has_padding) @as(usize, 1) else 0);
        const block_size = 8 + num_entries * 2;

        const block_size_u32 = @as(u32, @intCast(block_size));
        try reloc_bytes.appendNTimes(0, 4); // Dummy PageRVA
        try reloc_bytes.appendSlice(std.mem.asBytes(&block_size_u32));
        try reloc_bytes.appendNTimes(0, num_entries * 2);

        pre_idx += count;
    }

    if (reloc_bytes.items.len == 0) {
        const dummy_page_rva: u32 = 0x1000;
        const dummy_block_size: u32 = 8;
        try reloc_bytes.appendSlice(std.mem.asBytes(&dummy_page_rva));
        try reloc_bytes.appendSlice(std.mem.asBytes(&dummy_block_size));
    }

    if (reloc_bytes.items.len > 0) {
        var reloc_ms = MergedSection{
            .name = ".reloc",
            .kind = .rodata,
            .flags = .{},
            .alignment = 4,
        };
        try reloc_ms.bytes.appendSlice(allocator, reloc_bytes.items);
        reloc_ms.size = reloc_bytes.items.len;
        try linker.merged_sections.append(allocator, reloc_ms);
    }

    // Filter out debug and other non-executable sections (.debug*, .llvm_addrsig)
    {
        var i: usize = 0;
        while (i < linker.merged_sections.items.len) {
            const ms = linker.merged_sections.items[i];
            if (ms.size == 0 or
                std.mem.startsWith(u8, ms.name, ".debug") or
                std.mem.eql(u8, ms.name, ".llvm_addrsig") or
                std.mem.startsWith(u8, ms.name, ".llvm_ad")) {
                var removed_ms = linker.merged_sections.orderedRemove(i);
                removed_ms.deinit(allocator);
            } else {
                i += 1;
            }
        }
    }

    // 5. Assign PE virtual addresses and file offsets

    const image_base: u64 = 0x140000000;
    const section_alignment: u32 = 0x1000;
    const file_alignment: u32 = 0x200;

    const header_size = layout.alignTo(392 + linker.merged_sections.items.len * @sizeOf(IMAGE_SECTION_HEADER), file_alignment);
    linker.assignAddresses(image_base, section_alignment, file_alignment, header_size);

    // Get .idata merged section virtual address
    var idata_sec_opt: ?*MergedSection = null;
    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".idata")) {
            idata_sec_opt = ms;
            break;
        }
    }

    // 6. Patch .idata RVA references (add idata virtual address)
    if (idata_sec_opt) |idata_sec| {
        const idata_va = idata_sec.virtual_address - image_base; // PE optional header uses relative virtual addresses (RVAs)

        var desc_idx: usize = 0;
        while (true) {
            const offset = desc_idx * @sizeOf(IMAGE_IMPORT_DESCRIPTOR);
            if (offset + @sizeOf(IMAGE_IMPORT_DESCRIPTOR) > idata_sec.bytes.items.len) break;
            const desc = std.mem.bytesAsValue(IMAGE_IMPORT_DESCRIPTOR, idata_sec.bytes.items[offset .. offset + @sizeOf(IMAGE_IMPORT_DESCRIPTOR)]);
            if (desc.ImportLookupTableRVA == 0 and desc.NameRVA == 0) break;

            const ilt_off = desc.ImportLookupTableRVA;
            const iat_off = desc.ImportAddressTableRVA;

            // Patch descriptor RVAs
            desc.ImportLookupTableRVA += @intCast(idata_va);
            desc.NameRVA += @intCast(idata_va);
            desc.ImportAddressTableRVA += @intCast(idata_va);

            // Patch ILT entries (at ilt_off within idata_sec.bytes)
            var entry_off = ilt_off;
            while (entry_off + 8 <= idata_sec.bytes.items.len) : (entry_off += 8) {
                const val = std.mem.readInt(u64, idata_sec.bytes.items[entry_off..][0..8], .little);
                if (val == 0) break;
                std.mem.writeInt(u64, idata_sec.bytes.items[entry_off..][0..8], val + idata_va, .little);
            }

            // Patch IAT entries (at iat_off within idata_sec.bytes)
            entry_off = iat_off;
            while (entry_off + 8 <= idata_sec.bytes.items.len) : (entry_off += 8) {
                const val = std.mem.readInt(u64, idata_sec.bytes.items[entry_off..][0..8], .little);
                if (val == 0) break;
                std.mem.writeInt(u64, idata_sec.bytes.items[entry_off..][0..8], val + idata_va, .little);
            }

            desc_idx += 1;
        }
    }

    try linker.resolveSymbolAddresses();

    // Refresh text_sec pointer in case of ArrayList reallocation
    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".text")) {
            text_sec = ms;
            break;
        }
    }

    {
        var keys_it = linker.symbol_addresses.keyIterator();
        while (keys_it.next()) |k| {
            std.debug.print("[sym-dump] Symbol name: '{s}' -> 0x{x}\n", .{ k.*, linker.symbol_addresses.get(k.*).? });
        }
    }

    const entry_addr = linker.symbol_addresses.get(entry_name) orelse blk: {
        if (linker.symbol_addresses.get("main")) |addr| break :blk addr;
        if (linker.symbol_addresses.get("_start")) |addr| break :blk addr;
        return error.EntrySymbolNotFound;
    };

    // Map direct import symbols to jump stubs, and `__imp_` symbols to IAT slots!
    if (idata_sec_opt) |idata_sec| {
        const idata_va = idata_sec.virtual_address;

        var git = iat_slot_offsets.iterator();
        while (git.next()) |entry| {
            const imp_name = entry.key_ptr.*;
            const slot_offset = entry.value_ptr.*;

            // Patch the __imp_ symbol address to point to its IAT slot RVA/VA
            const iat_slot_va = idata_va + slot_offset;
            try linker.symbol_addresses.put(imp_name, iat_slot_va);
        }

        // Patch direct import symbols to point to their jump stubs
        for (jump_stubs.items) |stub| {
            const stub_va = text_sec.?.virtual_address + stub.stub_offset;
            try linker.symbol_addresses.put(stub.sym_name, stub_va);

            // Now, fill in the jump stub RIP-relative displacement!
            // Instruction: FF 25 <disp32>
            // We jump to the IAT slot.
            const imp_name = try std.fmt.allocPrint(allocator, "__imp_{s}", .{stub.sym_name});
            defer allocator.free(imp_name);

            const iat_slot_va = linker.symbol_addresses.get(imp_name) orelse {
                // No IAT slot: this is an intrinsic stub, not an import. Nothing to patch.
                continue;
            };
            const next_inst_va = stub_va + 6;
            std.debug.print("[debug-disp] imp_name={s} iat_slot_va=0x{x} next_inst_va=0x{x}\n", .{ imp_name, iat_slot_va, next_inst_va });
            const displacement = @as(i64, @intCast(iat_slot_va)) - @as(i64, @intCast(next_inst_va));

            std.mem.writeInt(i32, text_sec.?.bytes.items[stub.stub_offset + 2..][0..4], @intCast(displacement), .little);
        }
    }

    // Register intrinsic stub addresses in the global symbol table.
    for (intrinsic_stub_list.items) |stub| {
        const stub_va = text_sec.?.virtual_address + stub.stub_offset;
        try linker.symbol_addresses.put(stub.sym_name, stub_va);
    }

    // 8. Apply Relocations
    try linker.applyRelocations(image_base);

    // If we have a .reloc section, regenerate it with the actual RVAs
    var reloc_sec_opt: ?*MergedSection = null;
    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".reloc")) {
            reloc_sec_opt = ms;
            break;
        }
    }
    if (reloc_sec_opt) |reloc_sec| {
        if (linker.base_relocs.items.len == 0) {
            reloc_sec.bytes.clearRetainingCapacity();
            const dummy_page_rva: u32 = 0x1000;
            const dummy_block_size: u32 = 8;
            try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&dummy_page_rva));
            try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&dummy_block_size));
            reloc_sec.size = 8;
        } else {
            std.mem.sort(Linker.BaseReloc, linker.base_relocs.items, {}, struct {
                fn lessThan(_: void, a: Linker.BaseReloc, b: Linker.BaseReloc) bool {
                    return a.rva < b.rva;
                }
            }.lessThan);

            reloc_sec.bytes.clearRetainingCapacity();

            var br_idx: usize = 0;
            while (br_idx < linker.base_relocs.items.len) {
                const page_rva = linker.base_relocs.items[br_idx].rva & 0xFFFFF000;

                var count: usize = 0;
                while (br_idx + count < linker.base_relocs.items.len and
                       (linker.base_relocs.items[br_idx + count].rva & 0xFFFFF000) == page_rva) {
                    count += 1;
                }

                const has_padding = (count % 2 != 0);
                const num_entries = count + (if (has_padding) @as(usize, 1) else 0);
                const block_size = 8 + num_entries * 2;

                try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&page_rva));
                const block_size_u32 = @as(u32, @intCast(block_size));
                try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&block_size_u32));

                for (linker.base_relocs.items[br_idx..br_idx+count]) |br| {
                    const offset = @as(u16, @intCast(br.rva & 0x0FFF));
                    const entry = (@as(u16, br.type) << 12) | offset;
                    try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&entry));
                }
                if (has_padding) {
                    const entry: u16 = 0;
                    try reloc_sec.bytes.appendSlice(allocator, std.mem.asBytes(&entry));
                }

                br_idx += count;
            }
            reloc_sec.size = reloc_sec.bytes.items.len;
        }
    }

    // 9. Emit final PE image bytes
    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // MZ Header (64 bytes)
    var mz: [64]u8 = [_]u8{0} ** 64;
    mz[0] = 'M';
    mz[1] = 'Z';
    mz[2] = 0x80;
    mz[3] = 0x00;
    mz[4] = 0x01;
    mz[5] = 0x00;
    mz[8] = 0x04;
    mz[24] = 0x40;
    // Offset to PE signature
    std.mem.writeInt(u32, mz[0x3C..0x40], 0x80, .little);
    try out.appendSlice(&mz);

    // DOS Stub padding (64 bytes)
    try out.appendNTimes(0, 64);

    // PE signature: PE\x00\x00 (4 bytes)
    try out.appendSlice(&.{ 'P', 'E', 0, 0 });

    // COFF File Header (20 bytes)
    const num_sections = linker.merged_sections.items.len;
    var coff_hdr = [_]u8{0} ** 20;
    std.mem.writeInt(u16, coff_hdr[0..2], 0x8664, .little);
    std.mem.writeInt(u16, coff_hdr[2..4], @intCast(num_sections), .little);
    std.mem.writeInt(u32, coff_hdr[4..8], 0, .little); // TimeDateStamp
    std.mem.writeInt(u32, coff_hdr[8..12], 0, .little); // PointerToSymbolTable
    std.mem.writeInt(u32, coff_hdr[12..16], 0, .little); // NumberOfSymbols
    std.mem.writeInt(u16, coff_hdr[16..18], 0xF0, .little); // SizeOfOptionalHeader
    std.mem.writeInt(u16, coff_hdr[18..20], 0x0022, .little); // Characteristics: EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE
    try out.appendSlice(&coff_hdr);

    // Optional Header PE32+ (240 bytes / 0xF0)
    var opt = [_]u8{0} ** 240;
    // Magic: PE32+ (0x020b)
    std.mem.writeInt(u16, opt[0..2], 0x020B, .little);
    // Linker version
    opt[2] = 1;
    opt[3] = 0;

    // Sizes of code, data, bss
    var size_of_code: u32 = 0;
    var size_of_init_data: u32 = 0;
    var size_of_uninit_data: u32 = 0;
    var base_of_code: u32 = 0;

    for (linker.merged_sections.items) |ms| {
        const ms_size = @as(u32, @intCast(layout.alignTo(ms.size, file_alignment)));
        if (ms.kind == .text) {
            size_of_code += ms_size;
            base_of_code = @intCast(ms.virtual_address - image_base);
        } else if (ms.kind == .bss) {
            size_of_uninit_data += ms_size;
        } else {
            size_of_init_data += ms_size;
        }
    }

    std.mem.writeInt(u32, opt[4..8], size_of_code, .little);
    std.mem.writeInt(u32, opt[8..12], size_of_init_data, .little);
    std.mem.writeInt(u32, opt[12..16], size_of_uninit_data, .little);

    // Address of entry point RVA
    const entry_va = entry_addr - image_base;
    std.mem.writeInt(u32, opt[16..20], @intCast(entry_va), .little);
    // Base of code
    std.mem.writeInt(u32, opt[20..24], base_of_code, .little);

    // Image Base
    std.mem.writeInt(u64, opt[24..32], image_base, .little);
    // Section and File Alignments
    std.mem.writeInt(u32, opt[32..36], section_alignment, .little);
    std.mem.writeInt(u32, opt[36..40], file_alignment, .little);

    // OS/Subsystem versions (6.0)
    std.mem.writeInt(u16, opt[40..42], 6, .little); // Major OS
    std.mem.writeInt(u16, opt[42..44], 0, .little); // Minor OS
    std.mem.writeInt(u16, opt[48..50], 6, .little); // Major Subsystem
    std.mem.writeInt(u16, opt[50..52], 0, .little); // Minor Subsystem

    // Size of Image
    var size_of_image = header_size;
    for (linker.merged_sections.items) |ms| {
        size_of_image = @max(size_of_image, ms.virtual_address - image_base + ms.size);
    }
    size_of_image = layout.alignTo(size_of_image, section_alignment);
    std.mem.writeInt(u32, opt[56..60], @intCast(size_of_image), .little);

    // Size of Headers
    const size_of_headers = header_size;
    std.mem.writeInt(u32, opt[60..64], @intCast(size_of_headers), .little);

    // Subsystem: CUI (3)
    std.mem.writeInt(u16, opt[68..70], 3, .little);
    // DLL Characteristics (0x8160: NX_COMPAT | TERMINAL_SERVER_AWARE | DYNAMIC_BASE | HIGH_ENTROPY_VA)
    std.mem.writeInt(u16, opt[70..72], 0x8160, .little);

    // Stack and Heap parameters
    std.mem.writeInt(u64, opt[72..80], 0x100000, .little); // stack reserve
    std.mem.writeInt(u64, opt[80..88], 0x1000, .little); // stack commit
    std.mem.writeInt(u64, opt[88..96], 0x100000, .little); // heap reserve
    std.mem.writeInt(u64, opt[96..104], 0x1000, .little); // heap commit

    // Number of Data directories (16)
    std.mem.writeInt(u32, opt[108..112], 16, .little);

    // Fill Data directories:
    // Directory 1: Import Table (.idata RVA and Size)
    if (idata_sec_opt) |idata_sec| {
        const idata_va = idata_sec.virtual_address - image_base;
        std.mem.writeInt(u32, opt[120..124], @intCast(idata_va), .little);
        std.mem.writeInt(u32, opt[124..128], @intCast(idata_sec.size), .little);

        // Directory 12: Import Address Table (IAT)
        if (iat_total_size > 0) {
            const iat_va = idata_va + iat_start_offset;
            std.mem.writeInt(u32, opt[208..212], @intCast(iat_va), .little);
            std.mem.writeInt(u32, opt[212..216], @intCast(iat_total_size), .little);
        }
    }

    // Directory 3: Exception Table (.pdata RVA and Size)
    var pdata_sec_opt: ?*MergedSection = null;
    for (linker.merged_sections.items) |*ms| {
        if (std.mem.eql(u8, ms.name, ".pdata")) {
            pdata_sec_opt = ms;
            break;
        }
    }
    if (pdata_sec_opt) |pdata_sec| {
        const pdata_va = pdata_sec.virtual_address - image_base;
        std.mem.writeInt(u32, opt[136..140], @intCast(pdata_va), .little);
        std.mem.writeInt(u32, opt[140..144], @intCast(pdata_sec.size), .little);
    }

    // Directory 5: Base Relocation Table (.reloc RVA and Size)
    if (reloc_sec_opt) |reloc_sec| {
        const reloc_va = reloc_sec.virtual_address - image_base;
        std.mem.writeInt(u32, opt[152..156], @intCast(reloc_va), .little);
        std.mem.writeInt(u32, opt[156..160], @intCast(reloc_sec.size), .little);
    }

    // Directory 12: Import Address Table (.idata IAT subset)
    // Optional, can leave empty.

    try out.appendSlice(&opt);

    // Section Headers
    for (linker.merged_sections.items) |ms| {
        const raw_sz = if (ms.kind == .bss) 0 else layout.alignTo(ms.size, file_alignment);
        var sh = IMAGE_SECTION_HEADER{
            .Name = [_]u8{0} ** 8,
            .VirtualSize = @intCast(ms.size),
            .VirtualAddress = @intCast(ms.virtual_address - image_base),
            .SizeOfRawData = @intCast(raw_sz),
            .PointerToRawData = if (raw_sz == 0) 0 else @intCast(ms.file_offset),
            .Characteristics = 0,
        };

        const len = @min(ms.name.len, 8);
        @memcpy(sh.Name[0..len], ms.name[0..len]);

        if (std.mem.eql(u8, ms.name, ".reloc")) {
            sh.Characteristics = 0x42000040; // CNT_INIT_DATA | DISCARDABLE | READ
        } else {
            switch (ms.kind) {
                .text => sh.Characteristics = 0x60000020, // CNT_CODE | EXECUTE | READ
                .rodata => sh.Characteristics = 0x40000040, // CNT_INIT_DATA | READ
                .data => sh.Characteristics = 0xC0000040, // CNT_INIT_DATA | READ | WRITE
                .bss => sh.Characteristics = 0xC0000080, // CNT_UNINIT_DATA | READ | WRITE
            }
        }

        try out.appendSlice(std.mem.asBytes(&sh));
    }

    // Pad headers area to aligned size
    if (out.items.len < size_of_headers) {
        try out.appendNTimes(0, @intCast(size_of_headers - out.items.len));
    }

    // Write Section raw data
    for (linker.merged_sections.items) |ms| {
        if (ms.kind == .bss) continue;

        // Pad to file offset
        if (out.items.len < ms.file_offset) {
            try out.appendNTimes(0, @intCast(ms.file_offset - out.items.len));
        }

        try out.appendSlice(ms.bytes.items);

        // Pad section data to FileAlignment
        const aligned_size = layout.alignTo(ms.size, file_alignment);
        const pad = aligned_size - ms.size;
        if (pad > 0) {
            try out.appendNTimes(0, @intCast(pad));
        }
    }

    return out.toOwnedSlice();
}
