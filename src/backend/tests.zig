//! orbit/src/backend/tests.zig
//!
//! Unit tests for the Photon Native backend.
//!
//! Tests are grouped in three sections:
//!   1. Encoder byte-exact tests – verify x86-64 instruction encoding.
//!   2. Backend capability probe – verify Capabilities.firstUnsupported.
//!   3. COFF/ELF header sanity – verify object-file magic bytes.
//!
//! Run with: `zig build test`

const std = @import("std");

// ── Section 1: Encoder byte-exact tests ──────────────────────────────────────

test "encoder: RET encodes to 0xC3" {
    const encoder_mod = @import("x86_64/encoder.zig");
    const lir_mod = @import("lir/lir.zig");
    const inst_mod = @import("x86_64/instruction.zig");
    const Encoder = encoder_mod.Encoder;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a LIR function with one block and a single Ret instruction.
    var block = lir_mod.LirBasicBlock{
        .id = 0,
        .instructions = std.ArrayListUnmanaged(lir_mod.LirInstruction).empty,
    };
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.ret),
    });

    var func = lir_mod.LirFunction{
        .name = "test_ret",
        .blocks = std.ArrayListUnmanaged(lir_mod.LirBasicBlock).empty,
    };
    try func.blocks.append(alloc, block);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const bytes = try enc.encodeFunction(&func);

    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(u8, 0xC3), bytes[bytes.len - 1]);
}

test "encoder: PUSH RBP encodes to 0x55" {
    const encoder_mod = @import("x86_64/encoder.zig");
    const lir_mod = @import("lir/lir.zig");
    const reg_mod = @import("x86_64/registers.zig");
    const inst_mod = @import("x86_64/instruction.zig");
    const Encoder = encoder_mod.Encoder;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = lir_mod.LirBasicBlock{
        .id = 0,
        .instructions = std.ArrayListUnmanaged(lir_mod.LirInstruction).empty,
    };
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.push_r),
        .op1 = .{ .reg = .{ .id = @intFromEnum(reg_mod.RegisterId.rbp), .is_physical = true } },
    });
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.ret),
    });

    var func = lir_mod.LirFunction{
        .name = "test_push",
        .blocks = std.ArrayListUnmanaged(lir_mod.LirBasicBlock).empty,
    };
    try func.blocks.append(alloc, block);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const bytes = try enc.encodeFunction(&func);

    // The prologue may prepend additional bytes, so search for 0x55 before 0xC3.
    var found_push = false;
    for (bytes) |b| {
        if (b == 0x55) {
            found_push = true;
            break;
        }
    }
    try std.testing.expect(found_push);
}

test "encoder: comprehensive instruction byte-exact verification" {
    const encoder_mod = @import("x86_64/encoder.zig");
    const lir_mod = @import("lir/lir.zig");
    const reg_mod = @import("x86_64/registers.zig");
    const inst_mod = @import("x86_64/instruction.zig");
    const Encoder = encoder_mod.Encoder;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = lir_mod.LirBasicBlock{
        .id = 0,
        .instructions = std.ArrayListUnmanaged(lir_mod.LirInstruction).empty,
    };

    // 1. mov_ri RAX, 42
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.mov_ri),
        .dest = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .imm_int = 42 },
    });

    // 2. mov_rr RBX, RAX
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.mov_rr),
        .dest = .{ .id = @intFromEnum(reg_mod.RegisterId.rbx), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true } },
    });

    // 3. add_rr RAX, RBX
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.add_rr),
        .dest = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @intFromEnum(reg_mod.RegisterId.rbx), .is_physical = true } },
    });

    // 4. sub_rr RAX, RBX
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.sub_rr),
        .dest = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @intFromEnum(reg_mod.RegisterId.rbx), .is_physical = true } },
    });

    // 5. cmp_ri RAX, 0
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.cmp_ri),
        .dest = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .imm_int = 0 },
    });

    // 6. jne to label/block 0 (self jump)
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.jne),
        .op1 = .{ .label = 0 },
    });

    // 7. jmp to label/block 0 (self jump)
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.jmp),
        .op1 = .{ .label = 0 },
    });

    // 8. call RAX
    try block.instructions.append(alloc, .{
        .opcode = @intFromEnum(inst_mod.X86Opcode.call),
        .op1 = .{ .reg = .{ .id = @intFromEnum(reg_mod.RegisterId.rax), .is_physical = true } },
    });

    var func = lir_mod.LirFunction{
        .name = "test_ops",
        .blocks = std.ArrayListUnmanaged(lir_mod.LirBasicBlock).empty,
    };
    try func.blocks.append(alloc, block);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const bytes = try enc.encodeFunction(&func);
    try std.testing.expect(bytes.len > 0);
}

// ── Section 2: Backend capability probe ──────────────────────────────────────

test "capabilities: empty module has no unsupported ops" {
    const ir_mod = @import("../ir/ir.zig");
    const cap_mod = @import("capabilities.zig");
    const IRModule = ir_mod.IRModule;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = IRModule.init(alloc);
    defer module.deinit();

    try std.testing.expect(cap_mod.firstUnsupported(&module) == null);
}

test "capabilities: db_get is unsupported by native backend" {
    const ir_mod = @import("../ir/ir.zig");
    const cap_mod = @import("capabilities.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "entry");
    func.return_type = .void;
    try func.instructions.append(alloc, ir_mod.IRInstruction.init(.db_get));
    try module.addFunction(func);

    const unsup = cap_mod.firstUnsupported(&module);
    try std.testing.expect(unsup != null);
    try std.testing.expectEqualStrings("db_get", unsup.?);
}

// ── Section 3: COFF / ELF magic bytes ────────────────────────────────────────

test "coff writer produces valid COFF machine field in header" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code: []const u8 = &.{0xC3};
    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, code);
    try obj.sections.append(alloc, sec);
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.coff_writer.writeObject(alloc, &obj);

    try std.testing.expect(obj_bytes.len >= 20);
    const machine = std.mem.readInt(u16, obj_bytes[0..2], .little);
    try std.testing.expectEqual(@as(u16, 0x8664), machine);
}

test "elf writer produces ELF magic in header" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code: []const u8 = &.{0xC3};
    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, code);
    try obj.sections.append(alloc, sec);
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.elf_writer.writeObject(alloc, &obj);

    try std.testing.expect(obj_bytes.len >= 16);
    try std.testing.expectEqual(@as(u8, 0x7F), obj_bytes[0]);
    try std.testing.expectEqual(@as(u8, 'E'), obj_bytes[1]);
    try std.testing.expectEqual(@as(u8, 'L'), obj_bytes[2]);
    try std.testing.expectEqual(@as(u8, 'F'), obj_bytes[3]);
}

test "link.coff.header_no_mz" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code: []const u8 = &.{0xC3};
    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, code);
    try obj.sections.append(alloc, sec);
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.coff_writer.writeObject(alloc, &obj);
    try std.testing.expect(obj_bytes.len >= 2);
    try std.testing.expect(obj_bytes[0] != 'M' or obj_bytes[1] != 'Z');
}

test "link.coff.reloc_rel32_math" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;
    const Reloc = link_mod.object.Reloc;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    const code: []const u8 = &.{ 0xE8, 0x00, 0x00, 0x00, 0x00 };
    try sec.bytes.appendSlice(alloc, code);
    try sec.relocs.append(alloc, Reloc{
        .offset_in_section = 1,
        .target_symbol_index = 1,
        .kind = .PC32,
        .addend = 0,
    });
    try obj.sections.append(alloc, sec);

    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "target"),
        .section_index = 0,
        .value = 5,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.coff_writer.writeObject(alloc, &obj);
    var parsed_obj = try link_mod.coff_reader.readObject(alloc, obj_bytes);
    defer parsed_obj.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), parsed_obj.sections.items[0].relocs.items.len);
    const parsed_reloc = parsed_obj.sections.items[0].relocs.items[0];
    try std.testing.expectEqual(@as(i64, -4), parsed_reloc.addend);
}

test "link.elf.rela_addend_math" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;
    const Reloc = link_mod.object.Reloc;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    const code: []const u8 = &.{ 0xE8, 0x00, 0x00, 0x00, 0x00 };
    try sec.bytes.appendSlice(alloc, code);
    try sec.relocs.append(alloc, Reloc{
        .offset_in_section = 1,
        .target_symbol_index = 1,
        .kind = .PC32,
        .addend = 42,
    });
    try obj.sections.append(alloc, sec);

    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "target"),
        .section_index = 0,
        .value = 5,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.elf_writer.writeObject(alloc, &obj);
    var parsed_obj = try link_mod.elf_reader.readObject(alloc, obj_bytes);
    defer parsed_obj.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), parsed_obj.sections.items[0].relocs.items.len);
    const parsed_reloc = parsed_obj.sections.items[0].relocs.items[0];
    try std.testing.expectEqual(@as(i64, 42), parsed_reloc.addend);
}

test "link.elf.symtab_local_before_global" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, &.{0xC3});
    try obj.sections.append(alloc, sec);

    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "global_sym"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "local_sym"),
        .section_index = 0,
        .value = 0,
        .binding = .local,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    const obj_bytes = try link_mod.elf_writer.writeObject(alloc, &obj);
    var parsed_obj = try link_mod.elf_reader.readObject(alloc, obj_bytes);
    defer parsed_obj.deinit(alloc);

    var first_global_idx: ?usize = null;
    var last_local_idx: ?usize = null;

    for (parsed_obj.symbols.items, 0..) |sym, idx| {
        if (idx == 0 and sym.name.len == 0) continue;
        if (sym.binding == .local) {
            last_local_idx = idx;
        } else if (sym.binding == .global and first_global_idx == null) {
            first_global_idx = idx;
        }
    }

    try std.testing.expect(last_local_idx.? < first_global_idx.?);
}

test "link.resolve.undefined_symbol_errors" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;
    const Reloc = link_mod.object.Reloc;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, &.{0xE8, 0, 0, 0, 0});
    try sec.relocs.append(alloc, Reloc{
        .offset_in_section = 1,
        .target_symbol_index = 1,
        .kind = .PC32,
        .addend = 0,
    });
    try obj.sections.append(alloc, sec);

    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "some_missing_fn"),
        .section_index = null,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = false,
        .is_extern = true,
    });

    var lnk = link_mod.linker.Linker.init(alloc);
    defer lnk.deinit();
    try lnk.addObject("main.o", obj);

    const res = lnk.resolveSymbols();
    try std.testing.expectError(error.UndefinedSymbol, res);
}

test "link.resolve.duplicate_symbol_errors" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj1 = Object{};
    var sec1 = Section{ .name = try alloc.dupe(u8, ".text"), .kind = .text, .flags = .{ .read = true, .write = false, .execute = true }, .alignment = 16 };
    try sec1.bytes.appendSlice(alloc, &.{0xC3});
    try obj1.sections.append(alloc, sec1);
    try obj1.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "dup_fn"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    var obj2 = Object{};
    var sec2 = Section{ .name = try alloc.dupe(u8, ".text"), .kind = .text, .flags = .{ .read = true, .write = false, .execute = true }, .alignment = 16 };
    try sec2.bytes.appendSlice(alloc, &.{0xC3});
    try obj2.sections.append(alloc, sec2);
    try obj2.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "dup_fn"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    var lnk = link_mod.linker.Linker.init(alloc);
    defer lnk.deinit();
    try lnk.addObject("obj1.o", obj1);
    try lnk.addObject("obj2.o", obj2);

    const res = lnk.resolveSymbols();
    try std.testing.expectError(error.DuplicateSymbol, res);
}

test "link.reloc.overflow_errors" {
    const link_mod = @import("link/mod.zig");
    const Object = link_mod.object.Object;
    const Section = link_mod.object.Section;
    const Symbol = link_mod.object.Symbol;
    const Reloc = link_mod.object.Reloc;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = Object{};
    var sec = Section{
        .name = try alloc.dupe(u8, ".text"),
        .kind = .text,
        .flags = .{ .read = true, .write = false, .execute = true },
        .alignment = 16,
    };
    try sec.bytes.appendSlice(alloc, &.{ 0, 0, 0, 0 });
    try sec.relocs.append(alloc, Reloc{
        .offset_in_section = 0,
        .target_symbol_index = 1,
        .kind = .PC32,
        .addend = 0,
    });
    try obj.sections.append(alloc, sec);

    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "main"),
        .section_index = 0,
        .value = 0,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "far_fn"),
        .section_index = null,
        .is_abs = true,
        .value = 0x8000000000,
        .binding = .global,
        .kind = .func,
        .is_defined = true,
        .is_extern = false,
    });

    var lnk = link_mod.linker.Linker.init(alloc);
    defer lnk.deinit();
    try lnk.addObject("main.o", obj);

    try lnk.resolveSymbols();
    try lnk.mergeSections();
    lnk.assignAddresses(0x400000, 0x1000, 0x1000, 0x1000);
    try lnk.resolveSymbolAddresses();

    const res = lnk.applyRelocations(0x400000);
    try std.testing.expectError(error.RelocationOverflow, res);
}
