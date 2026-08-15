//! orbit/src/backend/tests.zig
//!
//! Unit tests for the Native backend.
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
        .opcode = @backingInt(inst_mod.X86Opcode.ret),
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
        .opcode = @backingInt(inst_mod.X86Opcode.push_r),
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rbp), .is_physical = true } },
    });
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.ret),
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
        .opcode = @backingInt(inst_mod.X86Opcode.mov_ri),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .imm_int = 42 },
    });

    // 2. mov_rr RBX, RAX
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.mov_rr),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rbx), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true } },
    });

    // 3. add_rr RAX, RBX
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.add_rr),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rbx), .is_physical = true } },
    });

    // 4. sub_rr RAX, RBX
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.sub_rr),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rbx), .is_physical = true } },
    });

    // 5. cmp_ri RAX, 0
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.cmp_ri),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .imm_int = 0 },
    });

    // 6. jne to label/block 0 (self jump)
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.jne),
        .op1 = .{ .label = 0 },
    });

    // 7. jmp to label/block 0 (self jump)
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.jmp),
        .op1 = .{ .label = 0 },
    });

    // 8. call RAX
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.call),
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true } },
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

test "encoder: setcc and movzx encoding" {
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

    // 1. sete_r RAX (low byte AL, RAX=0)
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.sete_r),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
    });

    // 2. sete_r R8 (low byte R8B, R8=8 -> requires REX.B)
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.sete_r),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.r8), .is_physical = true },
    });

    // 3. movzx_rr RAX, RAX
    try block.instructions.append(alloc, .{
        .opcode = @backingInt(inst_mod.X86Opcode.movzx_rr),
        .dest = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true },
        .op1 = .{ .reg = .{ .id = @backingInt(reg_mod.RegisterId.rax), .is_physical = true } },
    });

    var func = lir_mod.LirFunction{
        .name = "test_setcc",
        .blocks = std.ArrayListUnmanaged(lir_mod.LirBasicBlock).empty,
    };
    try func.blocks.append(alloc, block);

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const bytes = try enc.encodeFunction(&func);
    try std.testing.expect(bytes.len > 0);

    // Let's verify byte-exact values:
    // 1. sete_r RAX (dest=RAX=0, no REX since RAX < 4) -> 0x0F 0x94 0xC0
    // 2. sete_r R8 (dest=R8=8, dest >= 8 -> REX prefix 0x41, followed by 0x0F 0x94 0xC0)
    // 3. movzx_rr RAX, RAX -> REX.W prefix 0x48, followed by 0x0F 0xB6 0xC0

    // Check 1. sete_r RAX -> 0x0F, 0x94, 0xC0
    try std.testing.expectEqual(@as(u8, 0x0F), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x94), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0xC0), bytes[2]);

    // Check 2. sete_r R8 -> 0x41, 0x0F, 0x94, 0xC0
    try std.testing.expectEqual(@as(u8, 0x41), bytes[3]);
    try std.testing.expectEqual(@as(u8, 0x0F), bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x94), bytes[5]);
    try std.testing.expectEqual(@as(u8, 0xC0), bytes[6]);

    // Check 3. movzx_rr RAX, RAX -> 0x48, 0x0F, 0xB6, 0xC0
    try std.testing.expectEqual(@as(u8, 0x48), bytes[7]);
    try std.testing.expectEqual(@as(u8, 0x0F), bytes[8]);
    try std.testing.expectEqual(@as(u8, 0xB6), bytes[9]);
    try std.testing.expectEqual(@as(u8, 0xC0), bytes[10]);
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

test "capabilities: load_field and store_field are supported by native backend" {
    const ir_mod = @import("../ir/ir.zig");
    const cap_mod = @import("capabilities.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "entry");
    func.return_type = .void;
    try func.instructions.append(alloc, ir_mod.IRInstruction.init(.load_field));
    try func.instructions.append(alloc, ir_mod.IRInstruction.init(.store_field));
    try module.addFunction(func);

    const unsup = cap_mod.firstUnsupported(&module);
    try std.testing.expect(unsup == null);
}

test "native layout: model field offsets match C struct layout" {
    const layout_mod = @import("mir/model_layout.zig");
    const ir_mod = @import("../ir/ir.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    // User { id: int, name: string }  ->  id@0, name@8, size 16
    var user = ir_mod.IRModel.init(alloc, "User");
    try user.fields.append(alloc, .{ .name = "id", .type_name = "int" });
    try user.fields.append(alloc, .{ .name = "name", .type_name = "string" });
    try module.addModel(user);

    // Mixed { ok: bool, code: int, ratio: float, label: string }
    //  ->  ok@0, code@4, ratio@8, label@16
    var mixed = ir_mod.IRModel.init(alloc, "Mixed");
    try mixed.fields.append(alloc, .{ .name = "ok", .type_name = "bool" });
    try mixed.fields.append(alloc, .{ .name = "code", .type_name = "int" });
    try mixed.fields.append(alloc, .{ .name = "ratio", .type_name = "float" });
    try mixed.fields.append(alloc, .{ .name = "label", .type_name = "string" });
    try module.addModel(mixed);

    // Padded { flag: bool, a: int, b: int }  ->  flag@0, a@4, b@8
    var padded = ir_mod.IRModel.init(alloc, "Padded");
    try padded.fields.append(alloc, .{ .name = "flag", .type_name = "bool" });
    try padded.fields.append(alloc, .{ .name = "a", .type_name = "int" });
    try padded.fields.append(alloc, .{ .name = "b", .type_name = "int" });
    try module.addModel(padded);

    // Prim { a: u8, b: i16, c: i32, d: i64 }  ->  a@0, b@2, c@4, d@8
    var prim = ir_mod.IRModel.init(alloc, "Prim");
    try prim.fields.append(alloc, .{ .name = "a", .type_name = "u8" });
    try prim.fields.append(alloc, .{ .name = "b", .type_name = "i16" });
    try prim.fields.append(alloc, .{ .name = "c", .type_name = "i32" });
    try prim.fields.append(alloc, .{ .name = "d", .type_name = "i64" });
    try module.addModel(prim);

    var layout = try layout_mod.ModelLayout.compute(alloc, &module);
    defer layout.deinit(alloc);

    try std.testing.expectEqual(@as(i32, 0), layout.fieldOffset("User", "id").?);
    try std.testing.expectEqual(@as(i32, 8), layout.fieldOffset("User", "name").?);
    try std.testing.expectEqual(@as(i32, 0), layout.fieldOffset("Mixed", "ok").?);
    try std.testing.expectEqual(@as(i32, 4), layout.fieldOffset("Mixed", "code").?);
    try std.testing.expectEqual(@as(i32, 8), layout.fieldOffset("Mixed", "ratio").?);
    try std.testing.expectEqual(@as(i32, 16), layout.fieldOffset("Mixed", "label").?);
    try std.testing.expectEqual(@as(i32, 0), layout.fieldOffset("Padded", "flag").?);
    try std.testing.expectEqual(@as(i32, 4), layout.fieldOffset("Padded", "a").?);
    try std.testing.expectEqual(@as(i32, 8), layout.fieldOffset("Padded", "b").?);
    try std.testing.expectEqual(@as(i32, 0), layout.fieldOffset("Prim", "a").?);
    try std.testing.expectEqual(@as(i32, 2), layout.fieldOffset("Prim", "b").?);
    try std.testing.expectEqual(@as(i32, 4), layout.fieldOffset("Prim", "c").?);
    try std.testing.expectEqual(@as(i32, 8), layout.fieldOffset("Prim", "d").?);
}

test "native MIR: load_field/store_field carry resolved field offsets" {
    const builder_mod = @import("mir/builder.zig");
    const ir_mod = @import("../ir/ir.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var user = ir_mod.IRModel.init(alloc, "User");
    try user.fields.append(alloc, .{ .name = "id", .type_name = "int" });
    try user.fields.append(alloc, .{ .name = "name", .type_name = "string" });
    try module.addModel(user);

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .model = "User" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var alloc_instr = ir_mod.IRInstruction.init(.alloc);
    alloc_instr.dest = 0;
    alloc_instr.operand1 = .{ .int = 16 };
    try func.emit(alloc, alloc_instr);

    var store_id = ir_mod.IRInstruction.init(.store_field);
    store_id.operand1 = .{ .register = 0 };
    store_id.operand2 = .{ .string = "id" };
    store_id.operand3 = .{ .int = 42 };
    try func.emit(alloc, store_id);

    var store_name = ir_mod.IRInstruction.init(.store_field);
    store_name.operand1 = .{ .register = 0 };
    store_name.operand2 = .{ .string = "name" };
    store_name.operand3 = .{ .string = "hello" };
    try func.emit(alloc, store_name);

    var load_instr = ir_mod.IRInstruction.init(.load_field);
    load_instr.dest = 1;
    load_instr.operand1 = .{ .register = 0 };
    load_instr.operand2 = .{ .string = "id" };
    try func.emit(alloc, load_instr);

    var ret_instr = ir_mod.IRInstruction.init(.ret);
    ret_instr.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret_instr);

    try module.functions.append(alloc, func);

    var builder = builder_mod.MirBuilder.init(alloc);
    var mir = try builder.build(&module);
    defer mir.deinit();

    try std.testing.expect(mir.functions.items.len == 1);
    const mir_func = &mir.functions.items[0];
    const block = &mir_func.blocks.items[0];

    var found_store_id = false;
    var found_store_name = false;
    var found_load = false;
    for (block.instructions.items) |instr| {
        switch (instr.opcode) {
            .store_field => {
                if (instr.op2 == .imm_int and instr.op2.imm_int == 0 and instr.op3 == .imm_int and instr.op3.imm_int == 42) {
                    found_store_id = true;
                }
                if (instr.op2 == .imm_int and instr.op2.imm_int == 8 and instr.op3 == .imm_str) {
                    found_store_name = true;
                }
            },
            .load_field => {
                if (instr.dest.? == 1 and instr.op2 == .imm_int and instr.op2.imm_int == 0) {
                    found_load = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_store_id);
    try std.testing.expect(found_store_name);
    try std.testing.expect(found_load);
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
    try sec.bytes.appendSlice(alloc, &.{ 0xE8, 0, 0, 0, 0 });
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
    // Runtime functions (orbit_*) must be defined by the stub object; the native
    // linker only materialises non-orbit undefined symbols as DLL imports.
    try obj.symbols.append(alloc, Symbol{
        .name = try alloc.dupe(u8, "orbit_missing_runtime_fn"),
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

test "native end-to-end: return 42" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const backend_dir = std.fs.path.dirname(this_dir) orelse ".";
    const src_dir = std.fs.path.dirname(backend_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_dir = try std.fs.path.join(alloc, &.{ root_dir, ".native_test_tmp" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer {
        cwd.deleteTree(io, temp_dir) catch {};
    }

    const src_path = try std.fs.path.join(alloc, &.{ temp_dir, "test.orb" });
    const bin_path = try std.fs.path.join(alloc, &.{ temp_dir, "test_exe.exe" });

    var file = try cwd.createFile(io, src_path, .{ .truncate = true });
    var wb: [1024]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &wb);
    try fw.interface.writeAll("fn main() -> int {\n  return 42\n}\n");
    try fw.flush();
    file.close(io);

    // Check if the compiler binary exists before attempting subprocess execution
    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch {
        return error.SkipZigTest;
    };
    compiler_file.close(io);

    // Compile to object file first to inspect bytes
    const compile_result = std.process.run(alloc, io, .{
        .argv = &.{
            compiler_path,
            "build",
            src_path,
            "-o",
            bin_path,
            "--backend=native",
            "--emit=obj",
            "--verbose",
        },
    }) catch {
        return error.SkipZigTest;
    };
    defer alloc.free(compile_result.stdout);
    defer alloc.free(compile_result.stderr);

    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        return error.SkipZigTest;
    }

    // Read the object file and print the bytes of the text section
    const link_mod = @import("link/mod.zig");
    const builtin = @import("builtin");

    var obj_file = try cwd.openFile(io, bin_path, .{});
    const obj_len = try obj_file.length(io);
    const obj_bytes = try alloc.alloc(u8, obj_len);
    defer alloc.free(obj_bytes);
    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(obj_file, io, &read_buf);
    try reader.interface.readSliceAll(obj_bytes);
    obj_file.close(io);

    var obj = try switch (builtin.os.tag) {
        .windows => link_mod.coff_reader.readObject(alloc, obj_bytes),
        else => link_mod.elf_reader.readObject(alloc, obj_bytes),
    };
    defer obj.deinit(alloc);

    for (obj.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, ".text")) {
            std.debug.print("EMITTED BYTES: ", .{});
            for (sec.bytes.items) |b| {
                std.debug.print("{X:0>2} ", .{b});
            }
            std.debug.print("\n", .{});
        }
    }

    // Now link the object to an executable
    const exe_path = try std.mem.concat(alloc, u8, &.{ bin_path, ".exe" });
    const link_result = try std.process.run(alloc, io, .{
        .argv = &.{
            compiler_path,
            "build",
            src_path,
            "-o",
            exe_path,
            "--backend=native",
            "--linker=native",
            "--verbose",
        },
    });
    defer alloc.free(link_result.stdout);
    defer alloc.free(link_result.stderr);

    if (link_result.term != .exited or link_result.term.exited != 0) {
        std.debug.print("Linking failed!\nstdout:\n{s}\nstderr:\n{s}\n", .{ link_result.stdout, link_result.stderr });
        return error.LinkingFailed;
    }

    const run_result = try std.process.run(alloc, io, .{
        .argv = &.{exe_path},
    });
    defer alloc.free(run_result.stdout);
    defer alloc.free(run_result.stderr);

    try std.testing.expect(run_result.term == .exited);
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 42), run_result.term.exited);
    }
}

test "native in-memory end-to-end: IR to relocatable object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var ir_func = ir_mod.IRFunction.init(alloc, "main");
    ir_func.return_type = .int;

    // dest = load_const 42
    const reg_id = try ir_func.allocRegister(alloc, .int);
    var load_instr = ir_mod.IRInstruction.init(.load_const);
    load_instr.dest = reg_id;
    load_instr.operand1 = .{ .int = 42 };
    try ir_func.emit(alloc, load_instr);

    // ret reg_id
    var ret_instr = ir_mod.IRInstruction.init(.ret);
    ret_instr.operand1 = .{ .register = reg_id };
    try ir_func.emit(alloc, ret_instr);

    try ir_module.functions.append(alloc, ir_func);

    const atlas_mod = @import("../atlas.zig");
    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);

    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    // Verify generated relocatable object byte slice is non-empty
    try std.testing.expect(obj_bytes.len > 0);

    const link_mod = @import("link/mod.zig");
    const builtin_mod = @import("builtin");

    var parsed_obj = try switch (builtin_mod.os.tag) {
        .windows => link_mod.coff_reader.readObject(alloc, obj_bytes),
        else => link_mod.elf_reader.readObject(alloc, obj_bytes),
    };
    defer parsed_obj.deinit(alloc);

    try std.testing.expect(parsed_obj.sections.items.len > 0);
    var found_main = false;
    for (parsed_obj.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "orbit_main") or std.mem.eql(u8, sym.name, "main")) {
            found_main = true;
            break;
        }
    }
    try std.testing.expect(found_main);
}

test "native in-memory: model alloc/store_field/load_field/return emits field memory ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var user = ir_mod.IRModel.init(alloc, "User");
    try user.fields.append(alloc, .{ .name = "id", .type_name = "int" });
    try user.fields.append(alloc, .{ .name = "name", .type_name = "string" });
    try ir_module.addModel(user);

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .model = "User" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var alloc_instr = ir_mod.IRInstruction.init(.alloc);
    alloc_instr.dest = 0;
    alloc_instr.operand1 = .{ .int = 16 };
    try func.emit(alloc, alloc_instr);

    var store_id = ir_mod.IRInstruction.init(.store_field);
    store_id.operand1 = .{ .register = 0 };
    store_id.operand2 = .{ .string = "id" };
    store_id.operand3 = .{ .int = 42 };
    try func.emit(alloc, store_id);

    var store_name = ir_mod.IRInstruction.init(.store_field);
    store_name.operand1 = .{ .register = 0 };
    store_name.operand2 = .{ .string = "name" };
    store_name.operand3 = .{ .string = "hello" };
    try func.emit(alloc, store_name);

    var load_instr = ir_mod.IRInstruction.init(.load_field);
    load_instr.dest = 1;
    load_instr.operand1 = .{ .register = 0 };
    load_instr.operand2 = .{ .string = "id" };
    try func.emit(alloc, load_instr);

    var ret_instr = ir_mod.IRInstruction.init(.ret);
    ret_instr.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret_instr);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);
    try std.testing.expect(obj_bytes.len > 0);

    const link_mod = @import("link/mod.zig");
    const builtin_mod = @import("builtin");
    var parsed_obj = try switch (builtin_mod.os.tag) {
        .windows => link_mod.coff_reader.readObject(alloc, obj_bytes),
        else => link_mod.elf_reader.readObject(alloc, obj_bytes),
    };
    defer parsed_obj.deinit(alloc);

    var text_bytes = std.ArrayListUnmanaged(u8).empty;
    defer text_bytes.deinit(alloc);
    for (parsed_obj.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, ".text")) {
            try text_bytes.appendSlice(alloc, sec.bytes.items);
        }
    }
    try std.testing.expect(text_bytes.items.len > 0);

    // Store id@0: mov [r10], r11 -> 4D 89 1A
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x4D, 0x89, 0x1A }) != null);
    // Store name@8: mov [r10+8], r11 -> 4D 89 5A 08
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x4D, 0x89, 0x5A, 0x08 }) != null);
    // Load id@0: mov rax, [r10] -> 49 8B 02
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x49, 0x8B, 0x02 }) != null);
}

test "native end-to-end: model alloc/store_field/load_field returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // global_single_threaded uses the failing allocator, so subprocess spawns
    // OOM on Windows. Use a dedicated Threaded io with a real allocator.
    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    // @src().file is relative to the module root (src/), not to the process
    // cwd (the repo root), so derive paths from the real cwd instead.
    const repo_root = try std.process.currentPathAlloc(io, alloc);
    const src_dir = try std.fs.path.join(alloc, &.{ repo_root, "src" });
    const runtime_dir = try std.fs.path.join(alloc, &.{ src_dir, "runtime" });
    const temp_dir = try std.fs.path.join(alloc, &.{ repo_root, ".native_model_test_tmp" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer {
        cwd.deleteTree(io, temp_dir) catch {};
    }

    // Build the model IR in memory.
    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var user = ir_mod.IRModel.init(alloc, "User");
    try user.fields.append(alloc, .{ .name = "id", .type_name = "int" });
    try user.fields.append(alloc, .{ .name = "name", .type_name = "string" });
    try ir_module.addModel(user);

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .model = "User" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var alloc_instr = ir_mod.IRInstruction.init(.alloc);
    alloc_instr.dest = 0;
    alloc_instr.operand1 = .{ .int = 16 };
    try func.emit(alloc, alloc_instr);

    var store_id = ir_mod.IRInstruction.init(.store_field);
    store_id.operand1 = .{ .register = 0 };
    store_id.operand2 = .{ .string = "id" };
    store_id.operand3 = .{ .int = 42 };
    try func.emit(alloc, store_id);

    var store_name = ir_mod.IRInstruction.init(.store_field);
    store_name.operand1 = .{ .register = 0 };
    store_name.operand2 = .{ .string = "name" };
    store_name.operand3 = .{ .string = "hello" };
    try func.emit(alloc, store_name);

    var load_instr = ir_mod.IRInstruction.init(.load_field);
    load_instr.dest = 1;
    load_instr.operand1 = .{ .register = 0 };
    load_instr.operand2 = .{ .string = "id" };
    try func.emit(alloc, load_instr);

    var ret_instr = ir_mod.IRInstruction.init(.ret);
    ret_instr.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret_instr);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    // Write the native object to disk.
    const obj_ext = if (builtin_mod.os.tag == .windows) ".obj" else ".o";
    const obj_path = try std.fs.path.join(alloc, &.{ temp_dir, "orbit_model" ++ obj_ext });
    {
        var obj_file = try cwd.createFile(io, obj_path, .{ .truncate = true });
        var wb: [4096]u8 = undefined;
        var fw = std.Io.File.Writer.init(obj_file, io, &wb);
        try fw.interface.writeAll(obj_bytes);
        try fw.flush();
        obj_file.close(io);
    }

    // Minimal native stub: init the global arena and call orbit_main.
    const stub_path = try std.fs.path.join(alloc, &.{ temp_dir, "stub.c" });
    {
        var stub_file = try cwd.createFile(io, stub_path, .{ .truncate = true });
        var wb: [4096]u8 = undefined;
        var fw = std.Io.File.Writer.init(stub_file, io, &wb);
        try fw.interface.writeAll(
            \\#include "runtime.h"
            \\void* orbit_global_arena = NULL;
            \\extern int orbit_main(void);
            \\int main(void) {
            \\    orbit_string_pool_init(1024);
            \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
            \\    int code = orbit_main();
            \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
            \\    orbit_string_pool_cleanup();
            \\    return code;
            \\}
            \\
        );
        try fw.flush();
        stub_file.close(io);
    }

    const runtime_inc = runtime_dir;
    const runtime_inc_flag = try std.fmt.allocPrint(alloc, "-I{s}", .{runtime_inc});
    const exe_path = try std.fs.path.join(alloc, &.{ temp_dir, "model_test_exe.exe" });

    const link_result = try std.process.run(alloc, io, .{
        .argv = &.{
            "zig", "cc",
            obj_path,
            stub_path,
            runtime_inc_flag,
            "-o", exe_path,
            "-O0",
            "-w",
            "-s",
        },
    });
    defer alloc.free(link_result.stdout);
    defer alloc.free(link_result.stderr);

    if (link_result.term != .exited or link_result.term.exited != 0) {
        std.debug.print("Native link failed!\nstdout:\n{s}\nstderr:\n{s}\n", .{ link_result.stdout, link_result.stderr });
        return error.NativeModelLinkFailed;
    }

    const run_result = try std.process.run(alloc, io, .{ .argv = &.{exe_path} });
    defer alloc.free(run_result.stdout);
    defer alloc.free(run_result.stderr);

    try std.testing.expect(run_result.term == .exited);
    try std.testing.expectEqual(@as(u32, 42), run_result.term.exited);
}

/// Links a native object with a minimal runtime stub and returns the process
/// exit code. The stub carries the extern wrappers the native lowering relies
/// on for the static-inline collection accessors.
fn copyFileSimple(
    io: std.Io,
    alloc: std.mem.Allocator,
    src_dir: std.Io.Dir,
    src_path: []const u8,
    dst_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    var src_file = try src_dir.openFile(io, src_path, .{});
    defer src_file.close(io);
    const stat = try src_file.stat(io);
    const data = try alloc.alloc(u8, stat.size);
    defer alloc.free(data);
    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(src_file, io, &read_buf);
    try reader.interface.readSliceAll(data);

    var dst_file = try dst_dir.createFile(io, dst_path, .{ .truncate = true });
    defer dst_file.close(io);
    var write_buf: [8192]u8 = undefined;
    var writer = std.Io.File.Writer.init(dst_file, io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.flush();
}

fn runNativeRuntimeProgram(
    alloc: std.mem.Allocator,
    io: std.Io,
    is_windows: bool,
    obj_bytes: []const u8,
    stub_body: []const u8,
) !u32 {
    return runNativeRuntimeProgramOpts(alloc, io, is_windows, obj_bytes, stub_body, .{});
}

const NativeRunOpts = struct {
    /// Compile stub.c with -DORBIT_WITH_DB (pulls in database.c, needs the
    /// bundled sqlite3.h/import-lib) and deploy sqlite3.dll next to the exe.
    db: bool = false,
};

fn runNativeRuntimeProgramOpts(
    alloc: std.mem.Allocator,
    io: std.Io,
    is_windows: bool,
    obj_bytes: []const u8,
    stub_body: []const u8,
    opts: NativeRunOpts,
) !u32 {
    const repo_root = try std.process.currentPathAlloc(io, alloc);
    const src_dir = try std.fs.path.join(alloc, &.{ repo_root, "src" });
    const runtime_dir = try std.fs.path.join(alloc, &.{ src_dir, "runtime" });
    const temp_dir = try std.fs.path.join(alloc, &.{ repo_root, ".native_runtime_test_tmp" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer {
        cwd.deleteTree(io, temp_dir) catch {};
    }

    const obj_ext = if (is_windows) ".obj" else ".o";
    const obj_path = try std.fs.path.join(alloc, &.{ temp_dir, try std.fmt.allocPrint(alloc, "orbit_prog{s}", .{obj_ext}) });
    {
        var obj_file = try cwd.createFile(io, obj_path, .{ .truncate = true });
        var wb: [4096]u8 = undefined;
        var fw = std.Io.File.Writer.init(obj_file, io, &wb);
        try fw.interface.writeAll(obj_bytes);
        try fw.flush();
        obj_file.close(io);
    }

    const stub_path = try std.fs.path.join(alloc, &.{ temp_dir, "stub.c" });
    {
        var stub_file = try cwd.createFile(io, stub_path, .{ .truncate = true });
        var wb: [4096]u8 = undefined;
        var fw = std.Io.File.Writer.init(stub_file, io, &wb);
        try fw.interface.writeAll(
            \\#include "runtime.h"
            \\void* orbit_global_arena = NULL;
            \\extern int orbit_main(void);
            \\size_t orbit_list_len_native(OrbitList* list) { return orbit_list_len(list); }
            \\OrbitResult orbit_list_get_native(OrbitList* list, size_t index) { return orbit_list_get(list, index); }
            \\OrbitResult orbit_map_get_native(OrbitMap* map, const char* key) { return orbit_map_get(map, key); }
            \\bool orbit_map_has_native(OrbitMap* map, const char* key) { return orbit_map_has(map, key); }
            \\
        );
        try fw.interface.writeAll(stub_body);
        try fw.flush();
        stub_file.close(io);
    }

    const runtime_inc_flag = try std.fmt.allocPrint(alloc, "-I{s}", .{runtime_dir});
    const exe_path = try std.fs.path.join(alloc, &.{ temp_dir, "prog_exe.exe" });

    var link_args = std.ArrayListUnmanaged([]const u8).empty;
    try link_args.appendSlice(alloc, &.{ "zig", "cc", obj_path, stub_path, runtime_inc_flag, "-o", exe_path, "-O0", "-w", "-s" });
    if (opts.db) {
        // database.c needs the bundled sqlite3 header and the import library
        // (the real orbit_db_query_all symbols live in sqlite3.dll).
        const vendor_dir = try std.fs.path.join(alloc, &.{ src_dir, "runtime", "vendor" });
        const vendor_inc = try std.fmt.allocPrint(alloc, "-I{s}", .{vendor_dir});
        const sqlite3_lib = try std.fs.path.join(alloc, &.{ vendor_dir, "win-x64", "sqlite3.lib" });
        try link_args.appendSlice(alloc, &.{ "-DORBIT_WITH_DB", vendor_inc, sqlite3_lib });
    }

    const link_result = try std.process.run(alloc, io, .{ .argv = link_args.items });
    defer alloc.free(link_result.stdout);
    defer alloc.free(link_result.stderr);

    if (link_result.term != .exited or link_result.term.exited != 0) {
        std.debug.print("Native link failed!\nstdout:\n{s}\nstderr:\n{s}\n", .{ link_result.stdout, link_result.stderr });
        return error.NativeCollectionLinkFailed;
    }

    if (opts.db and is_windows) {
        // The exe imports sqlite3.dll at load time; deploy it next to the exe.
        const vendor_dir = try std.fs.path.join(alloc, &.{ src_dir, "runtime", "vendor" });
        const dll_src = try std.fs.path.join(alloc, &.{ vendor_dir, "win-x64", "sqlite3.dll" });
        const dll_dst = try std.fs.path.join(alloc, &.{ temp_dir, "sqlite3.dll" });
        copyFileSimple(io, alloc, cwd, dll_src, cwd, dll_dst) catch {};
    }

    const run_result = try std.process.run(alloc, io, .{ .argv = &.{exe_path} });
    defer alloc.free(run_result.stdout);
    defer alloc.free(run_result.stderr);

    try std.testing.expect(run_result.term == .exited);
    return run_result.term.exited;
}

const native_stub_main_body =
    \\int main(void) {
    \\    orbit_string_pool_init(1024);
    \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
    \\    int code = orbit_main();
    \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
    \\    orbit_string_pool_cleanup();
    \\    return code;
    \\}
    \\
;

test "native MIR: collection opcodes carry mapped operands" {
    const builder_mod = @import("mir/builder.zig");
    const ir_mod = @import("../ir/ir.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .list = null }); // r0
    _ = try func.allocRegister(alloc, .int); // r1
    _ = try func.allocRegister(alloc, .int); // r2
    _ = try func.allocRegister(alloc, .{ .map = null }); // r3
    _ = try func.allocRegister(alloc, .int); // r4
    _ = try func.allocRegister(alloc, .bool); // r5

    var create = ir_mod.IRInstruction.init(.list_create);
    create.dest = 0;
    create.operand1 = .{ .int = 4 };
    create.operand2 = .{ .int = 8 };
    try func.emit(alloc, create);

    var push = ir_mod.IRInstruction.init(.list_push);
    push.operand1 = .{ .register = 0 };
    push.operand2 = .{ .int = 42 };
    try func.emit(alloc, push);

    var get = ir_mod.IRInstruction.init(.list_get);
    get.dest = 1;
    get.operand1 = .{ .register = 0 };
    get.operand2 = .{ .int = 0 };
    try func.emit(alloc, get);

    var len = ir_mod.IRInstruction.init(.list_len);
    len.dest = 2;
    len.operand1 = .{ .register = 0 };
    try func.emit(alloc, len);

    var map_create = ir_mod.IRInstruction.init(.map_create);
    map_create.dest = 3;
    map_create.operand1 = .{ .int = 8 };
    try func.emit(alloc, map_create);

    var map_set = ir_mod.IRInstruction.init(.map_set);
    map_set.operand1 = .{ .register = 3 };
    map_set.operand2 = .{ .string = "k" };
    map_set.operand3 = .{ .int = 42 };
    try func.emit(alloc, map_set);

    var map_get = ir_mod.IRInstruction.init(.map_get);
    map_get.dest = 4;
    map_get.operand1 = .{ .register = 3 };
    map_get.operand2 = .{ .string = "k" };
    try func.emit(alloc, map_get);

    var map_has = ir_mod.IRInstruction.init(.map_has);
    map_has.dest = 5;
    map_has.operand1 = .{ .register = 3 };
    map_has.operand2 = .{ .string = "k" };
    try func.emit(alloc, map_has);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try module.functions.append(alloc, func);

    var builder = builder_mod.MirBuilder.init(alloc);
    var mir = try builder.build(&module);
    defer mir.deinit();

    const block = &mir.functions.items[0].blocks.items[0];
    var found_create = false;
    var found_push = false;
    var found_get = false;
    var found_len = false;
    var found_map_create = false;
    var found_map_set = false;
    var found_map_get = false;
    var found_map_has = false;

    for (block.instructions.items) |instr| {
        switch (instr.opcode) {
            .list_create => {
                found_create = true;
                try std.testing.expect(instr.op1 == .imm_int and instr.op1.imm_int == 4);
                try std.testing.expect(instr.op2 == .imm_int and instr.op2.imm_int == 8);
            },
            .list_push => {
                found_push = true;
                try std.testing.expect(instr.dest == null);
                try std.testing.expect(instr.op1 == .reg and instr.op1.reg == 0);
                try std.testing.expect(instr.op2 == .imm_int and instr.op2.imm_int == 42);
            },
            .list_get => {
                found_get = true;
                try std.testing.expect(instr.dest.? == 1);
                try std.testing.expect(instr.op2 == .imm_int and instr.op2.imm_int == 0);
            },
            .list_len => {
                found_len = true;
                try std.testing.expect(instr.dest.? == 2);
                try std.testing.expect(instr.op1 == .reg and instr.op1.reg == 0);
            },
            .map_create => {
                found_map_create = true;
                try std.testing.expect(instr.op1 == .imm_int and instr.op1.imm_int == 8);
            },
            .map_set => {
                found_map_set = true;
                try std.testing.expect(instr.dest == null);
                try std.testing.expect(instr.op2 == .imm_str and std.mem.eql(u8, instr.op2.imm_str, "k"));
            },
            .map_get => {
                found_map_get = true;
                try std.testing.expect(instr.op2 == .imm_str and std.mem.eql(u8, instr.op2.imm_str, "k"));
            },
            .map_has => {
                found_map_has = true;
                try std.testing.expect(instr.op2 == .imm_str and std.mem.eql(u8, instr.op2.imm_str, "k"));
            },
            else => {},
        }
    }

    try std.testing.expect(found_create);
    try std.testing.expect(found_push);
    try std.testing.expect(found_get);
    try std.testing.expect(found_len);
    try std.testing.expect(found_map_create);
    try std.testing.expect(found_map_set);
    try std.testing.expect(found_map_get);
    try std.testing.expect(found_map_has);
}

test "native in-memory: collection calls reserve an sret buffer and push element addresses" {
    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");
    const link_mod = @import("link/mod.zig");
    const builtin = @import("builtin");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .list = null }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.list_create);
    create.dest = 0;
    create.operand1 = .{ .int = 4 };
    create.operand2 = .{ .int = 8 };
    try func.emit(alloc, create);

    var push = ir_mod.IRInstruction.init(.list_push);
    push.operand1 = .{ .register = 0 };
    push.operand2 = .{ .int = 42 };
    try func.emit(alloc, push);

    var get = ir_mod.IRInstruction.init(.list_get);
    get.dest = 1;
    get.operand1 = .{ .register = 0 };
    get.operand2 = .{ .int = 0 };
    try func.emit(alloc, get);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    var obj = try switch (builtin.os.tag) {
        .windows => link_mod.coff_reader.readObject(alloc, obj_bytes),
        else => link_mod.elf_reader.readObject(alloc, obj_bytes),
    };
    defer obj.deinit(alloc);

    var text_bytes: std.ArrayList(u8) = .empty;
    defer text_bytes.deinit(alloc);
    for (obj.sections.items) |sec| {
        if (std.mem.eql(u8, sec.name, ".text")) {
            try text_bytes.appendSlice(alloc, sec.bytes.items);
        }
    }
    try std.testing.expect(text_bytes.items.len > 0);

    // sub rsp, 32 (sret buffer reserve)
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x48, 0x83, 0xEC, 0x20 }) != null);
    // sub rsp, 8 (element address push)
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x48, 0x83, 0xEC, 0x08 }) != null);
    // add rsp, 32 (buffer release)
    try std.testing.expect(std.mem.indexOf(u8, text_bytes.items, &.{ 0x48, 0x83, 0xC4, 0x20 }) != null);
}

test "native end-to-end: list create/push/get returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .list = null }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.list_create);
    create.dest = 0;
    create.operand1 = .{ .int = 4 };
    create.operand2 = .{ .int = 8 };
    try func.emit(alloc, create);

    var push = ir_mod.IRInstruction.init(.list_push);
    push.operand1 = .{ .register = 0 };
    push.operand2 = .{ .int = 42 };
    try func.emit(alloc, push);

    var get = ir_mod.IRInstruction.init(.list_get);
    get.dest = 1;
    get.operand1 = .{ .register = 0 };
    get.operand2 = .{ .int = 0 };
    try func.emit(alloc, get);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "native end-to-end: map create/set/get returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .map = null }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.map_create);
    create.dest = 0;
    create.operand1 = .{ .int = 8 };
    try func.emit(alloc, create);

    var set = ir_mod.IRInstruction.init(.map_set);
    set.operand1 = .{ .register = 0 };
    set.operand2 = .{ .string = "k" };
    set.operand3 = .{ .int = 42 };
    try func.emit(alloc, set);

    var get = ir_mod.IRInstruction.init(.map_get);
    get.dest = 1;
    get.operand1 = .{ .register = 0 };
    get.operand2 = .{ .string = "k" };
    try func.emit(alloc, get);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "native MIR: result opcodes carry mapped operands" {
    const builder_mod = @import("mir/builder.zig");
    const ir_mod = @import("../ir/ir.zig");
    const mir_mod = @import("mir/mir.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .result = null }); // r0
    _ = try func.allocRegister(alloc, .bool); // r1
    _ = try func.allocRegister(alloc, .int); // r2

    var ok_instr = ir_mod.IRInstruction.init(.result_ok);
    ok_instr.dest = 0;
    ok_instr.operand1 = .{ .int = 42 };
    try func.emit(alloc, ok_instr);

    var chk = ir_mod.IRInstruction.init(.result_is_ok);
    chk.dest = 1;
    chk.operand1 = .{ .register = 0 };
    try func.emit(alloc, chk);

    var unwrap = ir_mod.IRInstruction.init(.result_unwrap);
    unwrap.dest = 2;
    unwrap.operand1 = .{ .register = 0 };
    try func.emit(alloc, unwrap);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 2 };
    try func.emit(alloc, ret);

    try module.functions.append(alloc, func);

    var mir_builder = builder_mod.MirBuilder.init(alloc);
    var mir = try mir_builder.build(&module);
    defer mir.deinit();

    try std.testing.expectEqual(@as(usize, 1), mir.functions.items.len);
    const mf = &mir.functions.items[0];
    const instrs = mf.blocks.items[0].instructions.items;

    try std.testing.expectEqual(mir_mod.MirOpcode.result_ok, instrs[0].opcode);
    try std.testing.expectEqual(@as(?u32, 0), instrs[0].dest);
    try std.testing.expectEqual(mir_mod.MirOperand{ .imm_int = 42 }, instrs[0].op1);

    try std.testing.expectEqual(mir_mod.MirOpcode.result_is_ok, instrs[1].opcode);
    try std.testing.expectEqual(mir_mod.MirOperand{ .reg = 0 }, instrs[1].op1);

    try std.testing.expectEqual(mir_mod.MirOpcode.result_unwrap, instrs[2].opcode);
    try std.testing.expectEqual(@as(?u32, 2), instrs[2].dest);
    try std.testing.expectEqual(mir_mod.MirOperand{ .reg = 0 }, instrs[2].op1);
}

test "native in-memory: result ops emit arena alloc call" {
    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .result = null }); // r0
    _ = try func.allocRegister(alloc, .bool); // r1
    _ = try func.allocRegister(alloc, .int); // r2

    var ok_instr = ir_mod.IRInstruction.init(.result_ok);
    ok_instr.dest = 0;
    ok_instr.operand1 = .{ .int = 42 };
    try func.emit(alloc, ok_instr);

    var chk = ir_mod.IRInstruction.init(.result_is_ok);
    chk.dest = 1;
    chk.operand1 = .{ .register = 0 };
    try func.emit(alloc, chk);

    var unwrap = ir_mod.IRInstruction.init(.result_unwrap);
    unwrap.dest = 2;
    unwrap.operand1 = .{ .register = 0 };
    try func.emit(alloc, unwrap);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 2 };
    try func.emit(alloc, ret);

    try module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &module);
    const obj = try backend.emitObject(alloc);
    defer alloc.free(obj);

    var text_found = false;
    var i: usize = 0;
    while (i + 7 <= obj.len) : (i += 1) {
        // call orbit_alloc: E8 <rel32>
        if (obj[i] == 0xE8) {
            text_found = true;
            break;
        }
    }
    try std.testing.expect(text_found);
}

test "native end-to-end: result_ok then is_ok then unwrap returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .result = null }); // r0
    _ = try func.allocRegister(alloc, .bool); // r1
    _ = try func.allocRegister(alloc, .int); // r2

    var ok_instr = ir_mod.IRInstruction.init(.result_ok);
    ok_instr.dest = 0;
    ok_instr.operand1 = .{ .int = 42 };
    try func.emit(alloc, ok_instr);

    var chk = ir_mod.IRInstruction.init(.result_is_ok);
    chk.dest = 1;
    chk.operand1 = .{ .register = 0 };
    try func.emit(alloc, chk);

    var unwrap = ir_mod.IRInstruction.init(.result_unwrap);
    unwrap.dest = 2;
    unwrap.operand1 = .{ .register = 0 };
    try func.emit(alloc, unwrap);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 2 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "native end-to-end: result_err is not ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .result = null }); // r0
    _ = try func.allocRegister(alloc, .bool); // r1

    var err_instr = ir_mod.IRInstruction.init(.result_err);
    err_instr.dest = 0;
    err_instr.operand1 = .{ .int = 7 };
    err_instr.operand2 = .{ .string = "boom" };
    try func.emit(alloc, err_instr);

    var chk = ir_mod.IRInstruction.init(.result_is_ok);
    chk.dest = 1;
    chk.operand1 = .{ .register = 0 };
    try func.emit(alloc, chk);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "native MIR: union opcodes carry mapped operands" {
    const builder_mod = @import("mir/builder.zig");
    const ir_mod = @import("../ir/ir.zig");
    const mir_mod = @import("mir/mir.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var module = ir_mod.IRModule.init(alloc);
    defer module.deinit();

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .tagged_union = "Color" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.union_create);
    create.dest = 0;
    create.operand1 = .{ .string = "Color_TAG_Blue" };
    create.operand2 = .{ .int = 99 };
    try func.emit(alloc, create);

    var tag = ir_mod.IRInstruction.init(.union_get_tag);
    tag.dest = 1;
    tag.operand1 = .{ .register = 0 };
    try func.emit(alloc, tag);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try module.functions.append(alloc, func);

    var mir_builder = builder_mod.MirBuilder.init(alloc);
    var mir = try mir_builder.build(&module);
    defer mir.deinit();

    const instrs = mir.functions.items[0].blocks.items[0].instructions.items;

    try std.testing.expectEqual(mir_mod.MirOpcode.union_create, instrs[0].opcode);
    try std.testing.expectEqual(@as(?u32, 0), instrs[0].dest);
    try std.testing.expectEqual(mir_mod.MirOperand{ .imm_str = "Color_TAG_Blue" }, instrs[0].op1);
    try std.testing.expectEqual(mir_mod.MirOperand{ .imm_int = 99 }, instrs[0].op2);

    try std.testing.expectEqual(mir_mod.MirOpcode.union_get_tag, instrs[1].opcode);
    try std.testing.expectEqual(@as(?u32, 1), instrs[1].dest);
    try std.testing.expectEqual(mir_mod.MirOperand{ .reg = 0 }, instrs[1].op1);
}

test "native end-to-end: union create/get_tag returns variant index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    try ir_module.types.append(alloc, ir_mod.IRTypeDecl{
        .name = "Color",
        .kind = .union_type,
        .variants = &.{ try alloc.dupe(u8, "Red"), try alloc.dupe(u8, "Green"), try alloc.dupe(u8, "Blue") },
        .rich_variants = &.{},
        .methods = &.{},
    });

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .tagged_union = "Color" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.union_create);
    create.dest = 0;
    create.operand1 = .{ .string = "Color_TAG_Blue" };
    create.operand2 = .{ .int = 99 };
    try func.emit(alloc, create);

    var tag = ir_mod.IRInstruction.init(.union_get_tag);
    tag.dest = 1;
    tag.operand1 = .{ .register = 0 };
    try func.emit(alloc, tag);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "native end-to-end: union create/get_data returns stored data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    try ir_module.types.append(alloc, ir_mod.IRTypeDecl{
        .name = "Color",
        .kind = .union_type,
        .variants = &.{ try alloc.dupe(u8, "Red"), try alloc.dupe(u8, "Green"), try alloc.dupe(u8, "Blue") },
        .rich_variants = &.{},
        .methods = &.{},
    });

    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .{ .tagged_union = "Color" }); // r0
    _ = try func.allocRegister(alloc, .int); // r1

    var create = ir_mod.IRInstruction.init(.union_create);
    create.dest = 0;
    create.operand1 = .{ .string = "Color_TAG_Blue" };
    create.operand2 = .{ .int = 99 };
    try func.emit(alloc, create);

    var data = ir_mod.IRInstruction.init(.union_get_data);
    data.dest = 1;
    data.operand1 = .{ .register = 0 };
    try func.emit(alloc, data);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 99), code);
}

test "native end-to-end: SSE2 float arithmetic and comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // (10.0 + 4.0 - 4.0) * 2.0 / 5.0 = 4.0, then 4.0 > 3.5 -> true (1).
    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .float); // r0 = 10.0
    _ = try func.allocRegister(alloc, .float); // r1 = 4.0
    _ = try func.allocRegister(alloc, .float); // r2 = a
    _ = try func.allocRegister(alloc, .float); // r3 = b
    _ = try func.allocRegister(alloc, .float); // r4 = c
    _ = try func.allocRegister(alloc, .float); // r5 = d
    _ = try func.allocRegister(alloc, .bool); // r6 = e

    var c0 = ir_mod.IRInstruction.init(.load_const);
    c0.dest = 0;
    c0.operand1 = .{ .float = 10.0 };
    try func.emit(alloc, c0);

    var c1 = ir_mod.IRInstruction.init(.load_const);
    c1.dest = 1;
    c1.operand1 = .{ .float = 4.0 };
    try func.emit(alloc, c1);

    var add = ir_mod.IRInstruction.init(.add);
    add.dest = 2;
    add.operand1 = .{ .register = 0 };
    add.operand2 = .{ .register = 1 };
    try func.emit(alloc, add);

    var sub = ir_mod.IRInstruction.init(.sub);
    sub.dest = 3;
    sub.operand1 = .{ .register = 2 };
    sub.operand2 = .{ .register = 1 };
    try func.emit(alloc, sub);

    var mul = ir_mod.IRInstruction.init(.mul);
    mul.dest = 4;
    mul.operand1 = .{ .register = 3 };
    mul.operand2 = .{ .float = 2.0 };
    try func.emit(alloc, mul);

    var div = ir_mod.IRInstruction.init(.div);
    div.dest = 5;
    div.operand1 = .{ .register = 4 };
    div.operand2 = .{ .float = 5.0 };
    try func.emit(alloc, div);

    var gt = ir_mod.IRInstruction.init(.gt);
    gt.dest = 6;
    gt.operand1 = .{ .register = 5 };
    gt.operand2 = .{ .float = 3.5 };
    try func.emit(alloc, gt);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 6 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "native end-to-end: float negation via IEEE sign-bit flip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // x = 5.0; y = -x; return y < 0.0 (1). Exercises `.neg` on a float operand.
    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .float); // r0 = 5.0
    _ = try func.allocRegister(alloc, .float); // r1 = -5.0
    _ = try func.allocRegister(alloc, .bool); // r2 = y < 0.0

    var c0 = ir_mod.IRInstruction.init(.load_const);
    c0.dest = 0;
    c0.operand1 = .{ .float = 5.0 };
    try func.emit(alloc, c0);

    var neg = ir_mod.IRInstruction.init(.neg);
    neg.dest = 1;
    neg.operand1 = .{ .register = 0 };
    try func.emit(alloc, neg);

    var lt = ir_mod.IRInstruction.init(.lt);
    lt.dest = 2;
    lt.operand1 = .{ .register = 1 };
    lt.operand2 = .{ .float = 0.0 };
    try func.emit(alloc, lt);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 2 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "native end-to-end: float modulo via fmod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // fmod(10.5, 3.0) = 1.5; return 1.5 > 1.0 (1). Exercises `.mod` on float operands.
    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .float); // r0 = 10.5
    _ = try func.allocRegister(alloc, .float); // r1 = 3.0
    _ = try func.allocRegister(alloc, .float); // r2 = remainder
    _ = try func.allocRegister(alloc, .bool); // r3 = remainder > 1.0

    var c0 = ir_mod.IRInstruction.init(.load_const);
    c0.dest = 0;
    c0.operand1 = .{ .float = 10.5 };
    try func.emit(alloc, c0);

    var c1 = ir_mod.IRInstruction.init(.load_const);
    c1.dest = 1;
    c1.operand1 = .{ .float = 3.0 };
    try func.emit(alloc, c1);

    var mod = ir_mod.IRInstruction.init(.mod);
    mod.dest = 2;
    mod.operand1 = .{ .register = 0 };
    mod.operand2 = .{ .register = 1 };
    try func.emit(alloc, mod);

    var gt = ir_mod.IRInstruction.init(.gt);
    gt.dest = 3;
    gt.operand1 = .{ .register = 2 };
    gt.operand2 = .{ .float = 1.0 };
    try func.emit(alloc, gt);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 3 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "native end-to-end: float return and call through XMM0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // fn scale(x: float) -> float { return x * 2.0 }
    // main: scale(5.0) == 10.0 -> 1. Exercises float arg (XMM), float
    // `.ret` (XMM0) and float `.call` dest (read XMM0).
    var scale = ir_mod.IRFunction.init(alloc, "scale");
    scale.return_type = .float;
    scale.params = &.{"x"};
    scale.param_types = &.{.float};
    _ = try scale.allocRegister(alloc, .float); // r0 = result temp
    const scale_param_reg: u32 = @intCast(scale.register_types.items.len); // param register id

    var mul = ir_mod.IRInstruction.init(.mul);
    mul.dest = 0;
    mul.operand1 = .{ .register = scale_param_reg };
    mul.operand2 = .{ .float = 2.0 };
    try scale.emit(alloc, mul);

    var sret = ir_mod.IRInstruction.init(.ret);
    sret.operand1 = .{ .register = 0 };
    try scale.emit(alloc, sret);
    try ir_module.functions.append(alloc, scale);

    var main = ir_mod.IRFunction.init(alloc, "main");
    main.return_type = .int;
    _ = try main.allocRegister(alloc, .float); // r0 = 5.0
    _ = try main.allocRegister(alloc, .float); // r1 = scale result
    _ = try main.allocRegister(alloc, .bool); // r2 = r1 == 10.0

    var c0 = ir_mod.IRInstruction.init(.load_const);
    c0.dest = 0;
    c0.operand1 = .{ .float = 5.0 };
    try main.emit(alloc, c0);

    var arg = ir_mod.IRInstruction.init(.arg);
    arg.operand1 = .{ .register = 0 };
    try main.emit(alloc, arg);

    var call = ir_mod.IRInstruction.init(.call);
    call.dest = 1;
    call.operand1 = .{ .string = "scale" };
    call.operand2 = .{ .int = 1 };
    try main.emit(alloc, call);

    var eq = ir_mod.IRInstruction.init(.eq);
    eq.dest = 2;
    eq.operand1 = .{ .register = 1 };
    eq.operand2 = .{ .float = 10.0 };
    try main.emit(alloc, eq);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 2 };
    try main.emit(alloc, ret);
    try ir_module.functions.append(alloc, main);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

const sret_stub_body =
    \\OrbitResult orbit_stub_make(int v) {
    \\    return orbit_result_ok((void*)(long)v);
    \\}
    \\int main(void) {
    \\    orbit_string_pool_init(1024);
    \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
    \\    int code = orbit_main();
    \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
    \\    orbit_string_pool_cleanup();
    \\    return code;
    \\}
    \\
;

test "native end-to-end: sret call to OrbitResult-returning C function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // Generic `.call` to orbit_stub_make (24-byte OrbitResult -> sret). The MIR
    // builder injects sret_alloc (arena-allocated buffer in the .result dest),
    // the lowering passes the buffer as hidden arg 0 and the int as arg 1.
    // is_ok(unwrap(res)) checks the C-written ok/value fields.
    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .int); // r0 = 42
    _ = try func.allocRegister(alloc, .{ .result = null }); // r1 = OrbitResult*
    _ = try func.allocRegister(alloc, .bool); // r2 = is_ok
    _ = try func.allocRegister(alloc, .int); // r3 = unwrap
    _ = try func.allocRegister(alloc, .bool); // r4 = r3 == 42
    _ = try func.allocRegister(alloc, .bool); // r5 = r2 && r4

    var c0 = ir_mod.IRInstruction.init(.load_const);
    c0.dest = 0;
    c0.operand1 = .{ .int = 42 };
    try func.emit(alloc, c0);

    var arg = ir_mod.IRInstruction.init(.arg);
    arg.operand1 = .{ .register = 0 };
    try func.emit(alloc, arg);

    var call = ir_mod.IRInstruction.init(.call);
    call.dest = 1;
    call.operand1 = .{ .string = "orbit_stub_make" };
    call.operand2 = .{ .int = 1 };
    try func.emit(alloc, call);

    var is_ok = ir_mod.IRInstruction.init(.result_is_ok);
    is_ok.dest = 2;
    is_ok.operand1 = .{ .register = 1 };
    try func.emit(alloc, is_ok);

    var unwrap = ir_mod.IRInstruction.init(.result_unwrap);
    unwrap.dest = 3;
    unwrap.operand1 = .{ .register = 1 };
    try func.emit(alloc, unwrap);

    var eq = ir_mod.IRInstruction.init(.eq);
    eq.dest = 4;
    eq.operand1 = .{ .register = 3 };
    eq.operand2 = .{ .int = 42 };
    try func.emit(alloc, eq);

    var and_instr = ir_mod.IRInstruction.init(.and_op);
    and_instr.dest = 5;
    and_instr.operand1 = .{ .register = 2 };
    and_instr.operand2 = .{ .register = 4 };
    try func.emit(alloc, and_instr);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 5 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, sret_stub_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "native end-to-end: model constructor from source allocates and stores fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const Parser = @import("../parser.zig").Parser;
    const Sema = @import("../sema.zig").Sema;
    const IRBuilder = @import("../ir/builder.zig").IRBuilder;
    const backend_mod = @import("backend.zig");
    const atlas_mod = @import("../atlas.zig");

    const source =
        \\model User {
        \\    id: int
        \\    name: string
        \\}
        \\
        \\fn main() -> int {
        \\    val u = User(id: 42, name: "hello")
        \\    return u.id
        \\}
    ;

    var p = Parser.init(source, "models_from_source.orb", alloc);
    const root = try p.parse();

    var sema = try Sema.create(alloc, source);
    defer sema.deinit();
    sema.analyze(root) catch |err| {
        std.debug.print("sema failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(sema.diagnostics.getDiagnostics().len == 0);

    var builder = IRBuilder.init(alloc, source, &sema.node_types, &sema.model_registry);
    var ir_module = try builder.build(root);
    defer ir_module.deinit();

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, native_stub_main_body);
    try std.testing.expectEqual(@as(u32, 42), code);
}

const arena_stub_body =
    \\orbit_string orbit_db_query_all(OrbitArena* arena, const char* table_name) {
    \\    if (arena == (OrbitArena*)orbit_global_arena && strcmp(table_name, "users") == 0) return "OK";
    \\    return "BAD";
    \\}
    \\int main(void) {
    \\    orbit_string_pool_init(1024);
    \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
    \\    int code = orbit_main();
    \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
    \\    orbit_string_pool_cleanup();
    \\    return code;
    \\}
    \\
;

test "native end-to-end: arena-requiring call injects orbit_global_arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const backend_mod = @import("backend.zig");
    const ir_mod = @import("../ir/ir.zig");
    const atlas_mod = @import("../atlas.zig");

    var ir_module = ir_mod.IRModule.init(alloc);
    defer ir_module.deinit();

    // Generic `.call` to the real arena-requiring orbit_db_query_all (mirrors
    // the frontend's `User.all()` emission: only the table name is an explicit
    // arg). The MIR builder injects arena_arg, the lowering passes
    // orbit_global_arena as hidden arg 0 and the table as arg 1. The stub
    // (database.c is guarded by ORBIT_WITH_DB, so the real symbol is free)
    // verifies both.
    var func = ir_mod.IRFunction.init(alloc, "main");
    func.return_type = .int;
    _ = try func.allocRegister(alloc, .string); // r0 = call result
    _ = try func.allocRegister(alloc, .bool); // r1 = r0 == "OK"

    var arg = ir_mod.IRInstruction.init(.arg);
    arg.operand1 = .{ .string = "users" };
    try func.emit(alloc, arg);

    var call = ir_mod.IRInstruction.init(.call);
    call.dest = 0;
    call.operand1 = .{ .string = "orbit_db_query_all" };
    call.operand2 = .{ .int = 1 };
    try func.emit(alloc, call);

    var eq = ir_mod.IRInstruction.init(.eq);
    eq.dest = 1;
    eq.operand1 = .{ .register = 0 };
    eq.operand2 = .{ .string = "OK" };
    try func.emit(alloc, eq);

    var ret = ir_mod.IRInstruction.init(.ret);
    ret.operand1 = .{ .register = 1 };
    try func.emit(alloc, ret);

    try ir_module.functions.append(alloc, func);

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, arena_stub_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "native end-to-end: model User.all() from source reaches orbit_db_query_all with arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const Parser = @import("../parser.zig").Parser;
    const Sema = @import("../sema.zig").Sema;
    const IRBuilder = @import("../ir/builder.zig").IRBuilder;
    const backend_mod = @import("backend.zig");
    const atlas_mod = @import("../atlas.zig");

    // The full official DB integration path: model CRUD from source lowers to a
    // generic `.call orbit_db_query_all` whose arena arg the native backend
    // injects. The stub (database.c is guarded by ORBIT_WITH_DB) stands in for
    // sqlite and returns "OK" only when it received orbit_global_arena and the
    // "users" table name.
    const source =
        \\model User {
        \\    id: int
        \\    name: string
        \\}
        \\
        \\fn main() -> int {
        \\    val r = User.all()
        \\    if (r == "OK") {
        \\        return 1
        \\    }
        \\    return 0
        \\}
    ;

    var p = Parser.init(source, "db_from_source.orb", alloc);
    const root = try p.parse();

    var sema = try Sema.create(alloc, source);
    defer sema.deinit();
    sema.analyze(root) catch |err| {
        std.debug.print("sema failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(sema.diagnostics.getDiagnostics().len == 0);

    var builder = IRBuilder.init(alloc, source, &sema.node_types, &sema.model_registry);
    var ir_module = try builder.build(root);
    defer ir_module.deinit();

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgram(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, arena_stub_body);
    try std.testing.expectEqual(@as(u32, 1), code);
}

const sqlite_stub_body =
    \\int main(void) {
    \\    orbit_string_pool_init(1024);
    \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
    \\    orbit_db_init(":memory:");
    \\    bool ok = orbit_db_insert("users", "{\\\"id\\\":\\\"u1\\\",\\\"username\\\":\\\"alice\\\",\\\"email\\\":\\\"a@x.com\\\",\\\"role_name\\\":\\\"admin\\\"}");
    \\    int code = orbit_main();
    \\    orbit_db_close();
    \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
    \\    orbit_string_pool_cleanup();
    \\    return ok ? code : 100;
    \\}
    \\
;

test "native end-to-end: User.all() returns seeded rows from real SQLite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const Parser = @import("../parser.zig").Parser;
    const Sema = @import("../sema.zig").Sema;
    const IRBuilder = @import("../ir/builder.zig").IRBuilder;
    const backend_mod = @import("backend.zig");
    const atlas_mod = @import("../atlas.zig");

    // The complete official DB integration: real SQLite, no stub. The stub
    // main seeds one row into :memory:, then the Orbit program's User.all()
    // lowers to a generic `.call orbit_db_query_all` (arena arg injected) that
    // serialises the row to JSON — so the result is non-empty and main returns
    // 1. The stub returns 100 if the insert failed (so the test also proves
    // orbit_db_insert wrote the seeded row, not just that the query is
    // non-empty). Requires the bundled sqlite3.dll (deployed by NativeRunOpts.db).
    const source =
        \\model User {
        \\    id: int
        \\    name: string
        \\}
        \\
        \\fn main() -> int {
        \\    val r = User.all()
        \\    if (r == "[]") {
        \\        return 0
        \\    }
        \\    return 1
        \\}
    ;

    var p = Parser.init(source, "db_real_sqlite.orb", alloc);
    const root = try p.parse();

    var sema = try Sema.create(alloc, source);
    defer sema.deinit();
    sema.analyze(root) catch |err| {
        std.debug.print("sema failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(sema.diagnostics.getDiagnostics().len == 0);

    var builder = IRBuilder.init(alloc, source, &sema.node_types, &sema.model_registry);
    var ir_module = try builder.build(root);
    defer ir_module.deinit();

    var backend = backend_mod.Backend.init(alloc, atlas_mod.AtlasConfig{}, false);
    try backend.lower(alloc, &ir_module);
    const obj_bytes = try backend.emitObject(alloc);

    const code = try runNativeRuntimeProgramOpts(alloc, io, builtin_mod.os.tag == .windows, obj_bytes, sqlite_stub_body, .{ .db = true });
    try std.testing.expectEqual(@as(u32, 1), code);
}
