//! orbit/src/backend/backend.zig
//!
//! Entrypoint orchestrator for the Photon Native backend.
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

const coff_mod = @import("coff/coff.zig");
const CoffWriter = coff_mod.CoffWriter;

const elf_mod = @import("elf/elf.zig");
const ElfWriter = elf_mod.ElfWriter;

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
        const mir = self.mir_module orelse return error.MirNotReady;

        if (mir.functions.items.len == 0) {
            return error.EmptyModule;
        }

        // Process all functions, encoding each and accumulating code.
        // For multi-function programs we use the first function as the entry
        // point; complete multi-function linking is tracked in issue #NATIVE-2.
        var all_code = std.ArrayListUnmanaged(u8){};
        var entry_name: []const u8 = "main";

        for (mir.functions.items) |*func| {
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

            try all_code.appendSlice(self.allocator, code);

            if (std.mem.eql(u8, func.name, "main")) {
                entry_name = "main";
            }
        }

        self.obj_bytes = all_code.items;

        // Emit in the target object format.
        return switch (self.target.format) {
            .coff => blk: {
                var writer = CoffWriter.init(self.allocator);
                break :blk try writer.writeObject(all_code.items, entry_name);
            },
            .elf => blk: {
                var writer = ElfWriter.init(self.allocator);
                break :blk try writer.writeObject(all_code.items, entry_name);
            },
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

        return switch (self.target.format) {
            .coff => blk: {
                var writer = CoffWriter.init(self.allocator);
                break :blk try writer.writeObject(code, func_name);
            },
            .elf => blk: {
                var writer = ElfWriter.init(self.allocator);
                break :blk try writer.writeObject(code, func_name);
            },
            else => error.UnsupportedFormat,
        };
    }
};
