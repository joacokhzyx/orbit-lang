//! orbit/src/backend/backend.zig
//!
//! Entrypoint orchestrator for the Native backend.
//!
//! Coordinates the full lowering pipeline:
//!   IR Module
//!     → MIR (verified, target-independent)
//!     → LIR (register-allocated, target-specific)
//!     → Machine code bytes
//!     → Relocatable object (COFF/ELF)
//!
//! Two entry points:
//!   `Backend.lower`      – lower IR and cache the MIR for --emit=mir.
//!   `Backend.emitObject` – encode and package into a relocatable object.
//!
//! The legacy `compileToObj` is kept for unit tests that run outside the
//! driver pipeline.

const std = @import("std");
const builtin = @import("builtin");

const target_mod = @import("target.zig");
const Target = target_mod.Target;

const atlas_mod = @import("../atlas.zig");
const AtlasConfig = atlas_mod.AtlasConfig;

const ir_mod = @import("../ir/ir.zig");
const IRModule = ir_mod.IRModule;

const mir_mod = @import("mir/mir.zig");
const MirModule = mir_mod.MirModule;
const MirOperand = mir_mod.MirOperand;

const builder_mod = @import("mir/builder.zig");
const MirBuilder = builder_mod.MirBuilder;

const verifier_mod = @import("mir/verifier.zig");
const MirVerifier = verifier_mod.MirVerifier;

const lowering_mod = @import("x86_64/lowering.zig");
const Lowering = lowering_mod.Lowering;

const regalloc_mod = @import("lir/regalloc.zig");
const RegisterAllocator = regalloc_mod.RegisterAllocator;

const encoder_mod = @import("x86_64/encoder.zig");
const Encoder = encoder_mod.Encoder;

const link_mod = @import("link/mod.zig");
const Object = link_mod.object.Object;
const Section = link_mod.object.Section;
const Symbol = link_mod.object.Symbol;
const Reloc = link_mod.object.Reloc;
const RelocKind = link_mod.object.RelocKind;

// ── Public API ────────────────────────────────────────────────────────────────

pub const Backend = struct {
    allocator: std.mem.Allocator,
    target: Target,
    /// Config is stored for future use (output name, optimisation level, etc.)
    config: AtlasConfig,
    has_server_init: bool,
    /// Cached MIR module produced by `lower()`, used for --emit=mir.
    mir_module: ?MirModule = null,
    /// Cached machine-code bytes, set after `emitObject()`.
    obj_bytes: ?[]const u8 = null,

    // ── Construction ─────────────────────────────────────────────────────────

    /// Create a Backend that matches the host target.
    ///
    /// `config`          – Atlas project configuration (output name, etc.)
    /// `has_server_init` – true when the program uses Orbit's HTTP server API.
    pub fn init(
        allocator: std.mem.Allocator,
        config: AtlasConfig,
        has_server_init: bool,
    ) Backend {
        return .{
            .allocator = allocator,
            .target = Target.detectHost(),
            .config = config,
            .has_server_init = has_server_init,
        };
    }

    // ── Pipeline ─────────────────────────────────────────────────────────────

    /// Lower an IR module through MIR (with verification).
    /// Call this first; then optionally call `emitObject()`.
    /// The produced MirModule is cached in `self.mir_module`.
    pub fn lower(self: *Backend, allocator: std.mem.Allocator, ir_module: *const IRModule) !void {
        _ = allocator; // Backend uses its own allocator field
        var builder = MirBuilder.init(self.allocator);
        var mir = try builder.build(ir_module);

        var verifier = MirVerifier.init(self.allocator);
        try verifier.verify(&mir);

        self.mir_module = mir;
    }

    /// Encode the cached MIR into a relocatable object file and return its bytes.
    /// `lower()` must be called before `emitObject()`.
    pub fn emitObject(self: *Backend, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        if (self.mir_module == null) return error.MirNotReady;
        var mir = &self.mir_module.?;

        if (mir.functions.items.len == 0) {
            return error.EmptyModule;
        }

        // Collect and rewrite string literals
        var string_literals = std.ArrayListUnmanaged(u8){};
        defer string_literals.deinit(self.allocator);
        var string_literal_offsets = std.StringHashMap(u32).init(self.allocator);
        defer string_literal_offsets.deinit();
        var string_literal_syms = std.StringHashMap([]const u8).init(self.allocator);
        defer string_literal_syms.deinit();

        var str_counter: usize = 0;

        for (mir.functions.items) |*func| {
            for (func.blocks.items) |*block| {
                for (block.instructions.items) |*instr| {
                    const is_call = (instr.opcode == .call);
                    
                    const ops = [3]*MirOperand{ &instr.op1, &instr.op2, &instr.op3 };
                    for (ops, 0..) |op_ptr, op_idx| {
                        if (is_call and op_idx == 0) continue;
                        
                        if (op_ptr.* == .imm_str) {
                            const str = op_ptr.imm_str;
                            const sym_name = if (string_literal_syms.get(str)) |sym| sym else blk: {
                                const offset = @as(u32, @intCast(string_literals.items.len));
                                try string_literals.appendSlice(self.allocator, str);
                                try string_literals.append(self.allocator, 0);
                                try string_literal_offsets.put(str, offset);
                                
                                const sym = try std.fmt.allocPrint(self.allocator, "__str_{d}", .{str_counter});
                                str_counter += 1;
                                try string_literal_syms.put(str, sym);
                                break :blk sym;
                            };
                            op_ptr.* = .{ .imm_str = sym_name };
                        }
                    }
                }
            }
        }

        // Process all functions, encoding each and accumulating code.
        // For multi-function programs we use the first function as the entry
        // point; complete multi-function linking is tracked in issue #NATIVE-2.
        var all_code = std.ArrayListUnmanaged(u8){};
        var entry_name: []const u8 = "orbit_main";

        // Construct neutral Object
        var obj = Object{};
        defer obj.deinit(self.allocator);

        var symbol_map = std.StringHashMap(u32).init(self.allocator);
        defer symbol_map.deinit();

        var sec_relocs = std.ArrayListUnmanaged(Reloc){};
        defer sec_relocs.deinit(self.allocator);

        const TempReloc = struct {
            patch_offset: usize,
            symbol_name: []const u8,
            kind: RelocKind,
            addend: i64,
        };
        var temp_relocs = std.ArrayListUnmanaged(TempReloc){};
        defer {
            for (temp_relocs.items) |r| {
                self.allocator.free(r.symbol_name);
            }
            temp_relocs.deinit(self.allocator);
        }

        for (mir.functions.items) |*func| {
            const function_offset = all_code.items.len;

            // Lower MIR function → LIR
            var lowering = Lowering.init(self.allocator, self.target);
            var lir_func = try lowering.lowerFunction(func);
            defer lir_func.deinit(self.allocator);

            // Register allocation
            var regalloc = RegisterAllocator.init(self.allocator, .stack);
            var allocated = try regalloc.allocate(&lir_func);
            defer allocated.deinit(self.allocator);

            // Machine encoding
            var encoder = Encoder.init(self.allocator);
            defer encoder.deinit();
            const code = try encoder.encodeFunction(&allocated);

            // Register this function symbol in `obj.symbols`
            const final_name = if (std.mem.eql(u8, func.name, "main")) "orbit_main" else func.name;
            const sym_idx = @as(u32, @intCast(obj.symbols.items.len));
            try obj.symbols.append(self.allocator, Symbol{
                .name = try self.allocator.dupe(u8, final_name),
                .section_index = 0, // .text section is index 0
                .value = function_offset,
                .binding = .global,
                .kind = .func,
                .is_defined = true,
                .is_extern = false,
            });
            try symbol_map.put(func.name, sym_idx);
            if (std.mem.eql(u8, func.name, "main")) {
                try symbol_map.put("orbit_main", sym_idx);
            }

            // Process relocations generated by the encoder
            for (encoder.symbol_relocs.items) |rel| {
                try temp_relocs.append(self.allocator, .{
                    .patch_offset = function_offset + rel.patch_offset,
                    .symbol_name = try self.allocator.dupe(u8, rel.symbol_name),
                    .kind = rel.kind,
                    .addend = rel.addend,
                });
            }

            try all_code.appendSlice(self.allocator, code);

            if (std.mem.eql(u8, func.name, "main")) {
                entry_name = "orbit_main";
            }
        }

        const code_size_before_strings = all_code.items.len;
        try all_code.appendSlice(self.allocator, string_literals.items);

        var sym_it = string_literal_syms.iterator();
        while (sym_it.next()) |entry| {
            const str_val = entry.key_ptr.*;
            const sym_name = entry.value_ptr.*;
            const offset_in_pool = string_literal_offsets.get(str_val).?;
            const abs_offset = code_size_before_strings + offset_in_pool;
            
            const sym_idx = @as(u32, @intCast(obj.symbols.items.len));
            try obj.symbols.append(self.allocator, Symbol{
                .name = try self.allocator.dupe(u8, sym_name),
                .section_index = 0, // .text section is index 0
                .value = abs_offset,
                .binding = .local,
                .kind = .object,
                .is_defined = true,
                .is_extern = false,
            });
            try symbol_map.put(sym_name, sym_idx);
        }

        // Now resolve all relocations after string literals have been defined
        for (temp_relocs.items) |rel| {
            const target_sym_idx = if (symbol_map.get(rel.symbol_name)) |idx| idx else blk: {
                const idx = @as(u32, @intCast(obj.symbols.items.len));
                try obj.symbols.append(self.allocator, Symbol{
                    .name = try self.allocator.dupe(u8, rel.symbol_name),
                    .section_index = null,
                    .value = 0,
                    .binding = .global,
                    .kind = .func,
                    .is_defined = false,
                    .is_extern = true,
                });
                try symbol_map.put(rel.symbol_name, idx);
                break :blk idx;
            };

            try sec_relocs.append(self.allocator, .{
                .offset_in_section = rel.patch_offset,
                .target_symbol_index = target_sym_idx,
                .kind = rel.kind,
                .addend = rel.addend,
            });
        }

        self.obj_bytes = all_code.items;

        var sec = Section{
            .name = try self.allocator.dupe(u8, ".text"),
            .kind = .text,
            .flags = .{ .read = true, .write = false, .execute = true },
            .alignment = 16,
        };
        try sec.bytes.appendSlice(self.allocator, all_code.items);
        try sec.relocs.appendSlice(self.allocator, sec_relocs.items);
        try obj.sections.append(self.allocator, sec);

        // Add entry symbol if not already present
        if (!symbol_map.contains(entry_name)) {
            try obj.symbols.append(self.allocator, Symbol{
                .name = try self.allocator.dupe(u8, entry_name),
                .section_index = 0,
                .value = 0,
                .binding = .global,
                .kind = .func,
                .is_defined = true,
                .is_extern = false,
            });
        }

        // Emit in the target object format.
        return switch (self.target.format) {
            .coff => try @import("link/coff_writer.zig").writeObject(self.allocator, &obj),
            .elf => try @import("link/elf_writer.zig").writeObject(self.allocator, &obj),
            else => error.UnsupportedFormat,
        };
    }

    // ── Legacy API (used by unit tests) ──────────────────────────────────────

    /// Single-shot compile: lower IR and emit a relocatable object in one call.
    /// This is the old API used by tests; prefer `lower()` + `emitObject()` in
    /// the driver pipeline.
    pub fn compileToObj(
        self: *Backend,
        ir_module: *const IRModule,
        func_name: []const u8,
    ) ![]const u8 {
        try self.lower(self.allocator, ir_module);
        const mir = self.mir_module orelse return error.MirNotReady;

        if (mir.functions.items.len == 0) {
            return error.EmptyModule;
        }

        const first_func = &mir.functions.items[0];

        var lowering = Lowering.init(self.allocator, self.target);
        var lir_func = try lowering.lowerFunction(first_func);
        defer lir_func.deinit(self.allocator);

        var regalloc = RegisterAllocator.init(self.allocator, .stack);
        var allocated = try regalloc.allocate(&lir_func);
        defer allocated.deinit(self.allocator);

        var encoder = Encoder.init(self.allocator);
        defer encoder.deinit();
        const code = try encoder.encodeFunction(&allocated);

        // Construct neutral Object
        var obj = Object{};
        defer obj.deinit(self.allocator);

        var symbol_map = std.StringHashMap(u32).init(self.allocator);
        defer symbol_map.deinit();

        try obj.symbols.append(self.allocator, Symbol{
            .name = try self.allocator.dupe(u8, func_name),
            .section_index = 0,
            .value = 0,
            .binding = .global,
            .kind = .func,
            .is_defined = true,
            .is_extern = false,
        });
        try symbol_map.put(func_name, 0);

        var sec_relocs = std.ArrayListUnmanaged(Reloc){};
        defer sec_relocs.deinit(self.allocator);

        for (encoder.symbol_relocs.items) |rel| {
            const target_sym_idx = if (symbol_map.get(rel.symbol_name)) |idx| idx else blk: {
                const idx = @as(u32, @intCast(obj.symbols.items.len));
                try obj.symbols.append(self.allocator, Symbol{
                    .name = try self.allocator.dupe(u8, rel.symbol_name),
                    .section_index = null,
                    .value = 0,
                    .binding = .global,
                    .kind = .func,
                    .is_defined = false,
                    .is_extern = true,
                });
                try symbol_map.put(rel.symbol_name, idx);
                break :blk idx;
            };

            try sec_relocs.append(self.allocator, .{
                .offset_in_section = rel.patch_offset,
                .target_symbol_index = target_sym_idx,
                .kind = rel.kind,
                .addend = rel.addend,
            });
        }

        var sec = Section{
            .name = try self.allocator.dupe(u8, ".text"),
            .kind = .text,
            .flags = .{ .read = true, .write = false, .execute = true },
            .alignment = 16,
        };
        try sec.bytes.appendSlice(self.allocator, code);
        try sec.relocs.appendSlice(self.allocator, sec_relocs.items);
        try obj.sections.append(self.allocator, sec);

        return switch (self.target.format) {
            .coff => try @import("link/coff_writer.zig").writeObject(self.allocator, &obj),
            .elf => try @import("link/elf_writer.zig").writeObject(self.allocator, &obj),
            else => error.UnsupportedFormat,
        };
    }
};
