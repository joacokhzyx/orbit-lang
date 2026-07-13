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
    const coff_mod = @import("coff/coff.zig");
    const CoffWriter = coff_mod.CoffWriter;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A minimal x86-64 RET-only function: 0xC3
    const code: []const u8 = &.{0xC3};
    var writer = CoffWriter.init(alloc);
    const obj = try writer.writeObject(code, "main");

    // COFF object files start with the Machine field (0x8664 for x86-64 LE).
    try std.testing.expect(obj.len >= 20); // At least a COFF header
    const machine = std.mem.readInt(u16, obj[0..2], .little);
    try std.testing.expectEqual(@as(u16, 0x8664), machine);
}

test "elf writer produces ELF magic in header" {
    const elf_mod = @import("elf/elf.zig");
    const ElfWriter = elf_mod.ElfWriter;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code: []const u8 = &.{0xC3};
    var writer = ElfWriter.init(alloc);
    const obj = try writer.writeObject(code, "main");

    try std.testing.expect(obj.len >= 16);
    try std.testing.expectEqual(@as(u8, 0x7F), obj[0]);
    try std.testing.expectEqual(@as(u8, 'E'), obj[1]);
    try std.testing.expectEqual(@as(u8, 'L'), obj[2]);
    try std.testing.expectEqual(@as(u8, 'F'), obj[3]);
}
