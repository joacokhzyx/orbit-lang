//! orbit/src/main.zig
//!
//! Orbit compiler driver.  Parses CLI flags, runs the compilation pipeline
//! (Lexer → Parser → Sema → IR → Codegen → native/C), and reports structured
//! timings via the Photon build-cache and Terminal UI subsystems.
//!
//! Two backends are available:
//!   steel  – C-generation path (default, production-stable)
//!   native – Native backend path (x86-64 direct emission, experimental)
//!
//! Entry point: `pub fn main()`.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const Compiler = @import("compiler.zig").Compiler;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const CBackend = @import("codegen/c_backend.zig").CBackend;
const AtlasConfig = @import("atlas.zig").AtlasConfig;
const term = @import("terminal/terminal.zig");

// ── Native backend ────────────────────────────────────────────────────────────
const NativeBackend = @import("backend/backend.zig").Backend;
const Capabilities = @import("backend/capabilities.zig");
const NativeDiag = @import("backend/diagnostics.zig");
const MirBuilder = @import("backend/mir/builder.zig").MirBuilder;
const MirPrinter = @import("backend/mir/printer.zig").MirPrinter;

/// Which compilation backend to use.
pub const BackendMode = enum {
    /// Default: generate C, compile with zig cc.  Oracle / production path.
    steel,
    /// Native backend: lower to MIR → LIR → x86-64 machine code directly.
    /// Falls back to steel on unsupported features when mode is `auto`.
    native,
    /// Automatically selects native when fully supported, steel otherwise.
    auto,
};

/// Emit artefact selector for --emit= flag.
pub const EmitMode = enum {
    exe, // Default: linked executable
    obj, // Relocatable object file
    mir, // Human-readable MIR dump
    lir, // Not yet implemented
};

/// Linker selection mode.
pub const LinkerMode = enum {
    system,
    native,
};

const ORBIT_VERSION = "0.1.0-rc.2";

pub const CompilationProfiler = struct {
    timer: OrbitTimer,

    project_discovery_ns: u64 = 0,
    read_atlas_ns: u64 = 0,
    read_sources_ns: u64 = 0,
    hashing_ns: u64 = 0,
    parsing_ns: u64 = 0,
    sema_ns: u64 = 0,
    build_ir_ns: u64 = 0,
    optimize_ns: u64 = 0,
    gen_c_ns: u64 = 0,
    write_files_ns: u64 = 0,
    compile_app_ns: u64 = 0,
    compile_sqlite_ns: u64 = 0,
    linking_ns: u64 = 0,
    cache_lookup_ns: u64 = 0,
    total_ns: u64 = 0,

    pub fn start() CompilationProfiler {
        return .{
            .timer = OrbitTimer.start(),
        };
    }

    pub fn record(self: *CompilationProfiler, ns_field: *u64) void {
        const elapsed_s = self.timer.readSeconds();
        ns_field.* = @intFromFloat(elapsed_s * 1_000_000_000.0);
        self.timer.reset();
    }

    pub fn getTotalNs(self: *const CompilationProfiler) u64 {
        return self.project_discovery_ns +
            self.read_atlas_ns +
            self.read_sources_ns +
            self.hashing_ns +
            self.parsing_ns +
            self.sema_ns +
            self.build_ir_ns +
            self.optimize_ns +
            self.gen_c_ns +
            self.write_files_ns +
            self.compile_app_ns +
            self.compile_sqlite_ns +
            self.linking_ns +
            self.cache_lookup_ns;
    }

    pub fn printTimings(self: *CompilationProfiler, json_mode: bool) void {
        self.total_ns = self.getTotalNs();
        const total_s = @as(f64, @floatFromInt(self.total_ns)) / 1_000_000_000.0;
        if (json_mode) {
            std.debug.print(
                \\{{
                \\  "discovery_ms": {d:.3},
                \\  "read_atlas_ms": {d:.3},
                \\  "read_sources_ms": {d:.3},
                \\  "hashing_ms": {d:.3},
                \\  "parsing_ms": {d:.3},
                \\  "sema_ms": {d:.3},
                \\  "ir_ms": {d:.3},
                \\  "optimize_ms": {d:.3},
                \\  "gen_c_ms": {d:.3},
                \\  "write_files_ms": {d:.3},
                \\  "sqlite_compile_ms": {d:.3},
                \\  "app_compile_ms": {d:.3},
                \\  "linking_ms": {d:.3},
                \\  "cache_lookup_ms": {d:.3},
                \\  "total_ms": {d:.3}
                \\}}
                \\
            , .{
                @as(f64, @floatFromInt(self.project_discovery_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.read_atlas_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.read_sources_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.hashing_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.parsing_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.sema_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.build_ir_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.optimize_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.gen_c_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.write_files_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.compile_sqlite_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.compile_app_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.linking_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.cache_lookup_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0,
            });
        } else {
            std.debug.print("\nOrbit compilation profile\n\n", .{});
            std.debug.print("Discovery             {d:.2} ms\n", .{@as(f64, @floatFromInt(self.project_discovery_ns)) / 1_000_000.0});
            std.debug.print("Read sources          {d:.2} ms\n", .{@as(f64, @floatFromInt(self.read_sources_ns)) / 1_000_000.0});
            std.debug.print("Hashing               {d:.2} ms\n", .{@as(f64, @floatFromInt(self.hashing_ns)) / 1_000_000.0});
            std.debug.print("Parsing               {d:.2} ms\n", .{@as(f64, @floatFromInt(self.parsing_ns)) / 1_000_000.0});
            std.debug.print("Sema                  {d:.2} ms\n", .{@as(f64, @floatFromInt(self.sema_ns)) / 1_000_000.0});
            std.debug.print("IR                    {d:.2} ms\n", .{@as(f64, @floatFromInt(self.build_ir_ns)) / 1_000_000.0});
            std.debug.print("C generation          {d:.2} ms\n", .{@as(f64, @floatFromInt(self.gen_c_ns)) / 1_000_000.0});
            if (self.compile_sqlite_ns > 0) {
                std.debug.print("SQLite compilation    {d:.2} ms\n", .{@as(f64, @floatFromInt(self.compile_sqlite_ns)) / 1_000_000.0});
            }
            if (self.compile_app_ns > 0) {
                std.debug.print("Native compilation    {d:.2} ms\n", .{@as(f64, @floatFromInt(self.compile_app_ns)) / 1_000_000.0});
            }
            if (self.linking_ns > 0) {
                std.debug.print("Linking               {d:.2} ms\n", .{@as(f64, @floatFromInt(self.linking_ns)) / 1_000_000.0});
            }
            if (self.cache_lookup_ns > 0) {
                std.debug.print("Cache lookup          {d:.2} ms\n", .{@as(f64, @floatFromInt(self.cache_lookup_ns)) / 1_000_000.0});
            }
            std.debug.print("Total                 {d:.2} ms ({d:.3}s)\n\n", .{ @as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0, total_s });
        }
    }
};

pub const CompilationSession = struct {
    arena: std.mem.Allocator,
    config: AtlasConfig,
    no_kynx: bool,
    debug: bool,
    verbose: bool,
    timings: bool,
    timings_json: bool,
    project_hash: u64 = 0,
    profiler: CompilationProfiler,
    compiler: Compiler,

    pub fn init(init_ctx: std.process.Init, file_path: []const u8, no_kynx: bool, debug: bool, verbose: bool, timings: bool, timings_json: bool, config: AtlasConfig) !CompilationSession {
        var profiler = CompilationProfiler.start();
        const arena = init_ctx.arena.allocator();

        // Phase 1: Project Discovery
        profiler.record(&profiler.project_discovery_ns);

        // Phase 2: Read Atlas
        profiler.record(&profiler.read_atlas_ns);

        // Phase 3: Read sources
        var compiler = Compiler.init(arena);
        try compiler.loadEntry(init_ctx.io, file_path);
        profiler.record(&profiler.read_sources_ns);

        // Phase 4: Hashing
        var project_hash: u64 = 14695981039346656037;
        for (compiler.units.items) |unit| {
            project_hash = fnv1a_combine(project_hash, unit.file_path);
            project_hash = fnv1a_combine(project_hash, unit.source);
        }

        // Combine with options
        project_hash = fnv1a_combine(project_hash, if (no_kynx) "no_kynx" else "kynx");
        project_hash = fnv1a_combine(project_hash, if (debug) "debug" else "release");
        project_hash = fnv1a_combine(project_hash, config.project);
        project_hash = fnv1a_combine(project_hash, config.version);
        const builtin = @import("builtin");
        project_hash = fnv1a_combine(project_hash, @tagName(builtin.os.tag));
        project_hash = fnv1a_combine(project_hash, @tagName(builtin.cpu.arch));

        profiler.record(&profiler.hashing_ns);

        return .{
            .arena = arena,
            .config = config,
            .no_kynx = no_kynx,
            .debug = debug,
            .verbose = verbose,
            .timings = timings,
            .timings_json = timings_json,
            .project_hash = project_hash,
            .profiler = profiler,
            .compiler = compiler,
        };
    }

    pub fn deinit(self: *CompilationSession) void {
        self.compiler.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "bootstrap")) {
        try runBootstrapMode(init, args);
        return;
    }

    if (args.len < 3) {
        printHelp();
        return;
    }

    const file_path = args[2];
    const config = AtlasConfig.load(arena, init.io) catch AtlasConfig{};

    var debug = false;
    var no_kynx = config.no_kynx;
    var verbose = false;
    var timings = false;
    var timings_json = false;
    var color_pref = term.ColorPreference.auto;
    var unicode_pref = term.UnicodePreference.auto;
    var backend_mode: BackendMode = .steel;
    var emit_mode: EmitMode = .exe;
    var linker_mode: LinkerMode = .system;
    var output_override: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
        if (std.mem.eql(u8, arg, "--no-kynx")) no_kynx = true;
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true;
        if (std.mem.eql(u8, arg, "--timings")) timings = true;
        if (std.mem.eql(u8, arg, "--timings=json")) {
            timings = true;
            timings_json = true;
        }
        if (std.mem.eql(u8, arg, "--color=auto")) color_pref = .auto;
        if (std.mem.eql(u8, arg, "--color=always")) color_pref = .always;
        if (std.mem.eql(u8, arg, "--color=never")) color_pref = .never;
        if (std.mem.eql(u8, arg, "--unicode=auto")) unicode_pref = .auto;
        if (std.mem.eql(u8, arg, "--unicode=always")) unicode_pref = .always;
        if (std.mem.eql(u8, arg, "--unicode=never")) unicode_pref = .never;
        // Backend selection
        if (std.mem.eql(u8, arg, "--backend=steel")) backend_mode = .steel;
        if (std.mem.eql(u8, arg, "--backend=native")) backend_mode = .native;
        if (std.mem.eql(u8, arg, "--backend=auto")) backend_mode = .auto;
        // Linker selection
        if (std.mem.eql(u8, arg, "--linker=system")) linker_mode = .system;
        if (std.mem.eql(u8, arg, "--linker=native")) linker_mode = .native;
        // Emit format
        if (std.mem.eql(u8, arg, "--emit=exe")) emit_mode = .exe;
        if (std.mem.eql(u8, arg, "--emit=obj")) emit_mode = .obj;
        if (std.mem.eql(u8, arg, "--emit=mir")) emit_mode = .mir;
        // Output path override
        if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
            output_override = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_override = arg["--output=".len..];
        }
    }

    _ = term.init(color_pref, unicode_pref, init.io, init.environ_map);

    if (std.mem.eql(u8, command, "dev") or std.mem.eql(u8, command, "run")) {
        try runExecuteMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config, backend_mode, emit_mode, linker_mode);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuildMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config, backend_mode, emit_mode, output_override, linker_mode);
    } else if (std.mem.eql(u8, command, "test")) {
        try runTestMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config, backend_mode, emit_mode, linker_mode);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    const yellow = term.style.getEsc(.bold_warning);
    const reset = term.style.getReset();

    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Orbit Compiler v{s}", .{ORBIT_VERSION}) catch "Orbit Compiler";

    var opt1: [128]u8 = undefined;
    const opt1_s = std.fmt.bufPrint(&opt1, "  {s}--backend=MODE{s}   steel (C engine), native (x86_64 direct)", .{ yellow, reset }) catch "";
    var opt2: [128]u8 = undefined;
    const opt2_s = std.fmt.bufPrint(&opt2, "  {s}--emit=MODE{s}      exe (default), obj, mir", .{ yellow, reset }) catch "";
    var opt3: [128]u8 = undefined;
    const opt3_s = std.fmt.bufPrint(&opt3, "  {s}--timings{s}        Show phase-by-phase compilation profiler", .{ yellow, reset }) catch "";
    var opt4: [128]u8 = undefined;
    const opt4_s = std.fmt.bufPrint(&opt4, "  {s}--no-kynx{s}        Disable Kynx safety verification", .{ yellow, reset }) catch "";

    var kynx_buf: [512]u8 = undefined;
    const kynx_line = term.layout.renderGradientTextBuf(&kynx_buf, "Secured by Kynx", .{ 96, 165, 250 }, .{ 30, 58, 138 });

    const lines = [_][]const u8{
        "USAGE",
        "  orbit <command> <file.orb> [options]",
        "",
        "COMMANDS",
        "  dev        Compile + instant execution with diagnostics",
        "  run        Compile + run and propagate process exit code",
        "  build      Compile to standalone native optimized binary",
        "  test       Execute isolated runtime unit tests",
        "  bootstrap  Run multi-stage self-hosting compiler build",
        "",
        "FLAGS & OPTIONS",
        opt1_s,
        opt2_s,
        opt3_s,
        opt4_s,
        "",
        kynx_line,
    };

    term.layout.renderBoxCardStderr(title, &lines, 68);
}

fn getOrCompileSqliteCache(init: std.process.Init, arena: std.mem.Allocator, sqlite_c: []const u8, sqlite_inc_dir: []const u8, verbose: bool, profiler: *CompilationProfiler) ![]const u8 {
    const cache_dir = try getOrbitCacheDir(init, arena);
    const builtin = @import("builtin");
    const obj_ext = if (builtin.os.tag == .windows) ".obj" else ".o";
    const cache_obj_name = try std.fmt.allocPrint(arena, "sqlite3_{s}_{s}{s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), obj_ext });
    const cache_obj_path = try std.fs.path.join(arena, &.{ cache_dir, cache_obj_name });

    var exists = false;
    var cwd = std.Io.Dir.cwd();
    if (cwd.openFile(init.io, cache_obj_path, .{})) |f| {
        f.close(init.io);
        exists = true;
    } else |_| {}

    if (!exists) {
        if (verbose) {
            std.debug.print("Photon: compiling SQLite to cache: {s}\n", .{cache_obj_path});
        }
        var sqlite_timer = OrbitTimer.start();

        var sqlite_args = std.ArrayListUnmanaged([]const u8).empty;
        try sqlite_args.append(arena, "zig");
        try sqlite_args.append(arena, "cc");
        try sqlite_args.append(arena, "-c");
        try sqlite_args.append(arena, sqlite_c);
        try sqlite_args.append(arena, "-o");
        try sqlite_args.append(arena, cache_obj_path);
        try sqlite_args.append(arena, "-O3");
        try sqlite_args.append(arena, sqlite_inc_dir);

        if (verbose) {
            std.debug.print("Executing: zig cc -c {s} -o {s} -O3 {s}\n", .{ sqlite_c, cache_obj_path, sqlite_inc_dir });
        }
        var child = try std.process.spawn(init.io, .{
            .argv = sqlite_args.items,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term_status = try child.wait(init.io);
        if (term_status != .exited or term_status.exited != 0) {
            return error.SqliteCompilationFailed;
        }

        profiler.compile_sqlite_ns = @intFromFloat(sqlite_timer.readSeconds() * 1_000_000_000.0);
    } else {
        if (verbose) {
            std.debug.print("Photon: SQLite cache HIT: {s}\n", .{cache_obj_path});
        }
    }
    return cache_obj_path;
}

fn compileToBinary(
    init: std.process.Init,
    session: *CompilationSession,
    out_bin_path: []const u8,
    out_c_path: []const u8,
    backend_mode: BackendMode,
    emit_mode: EmitMode,
    linker_mode: LinkerMode,
) ![]const u8 {
    const arena = session.arena;
    var profiler = &session.profiler;

    const root = try session.compiler.mergedRoots();
    const source = try session.compiler.mergedSource();

    var sema = try Sema.create(arena, source);
    defer sema.deinit();
    sema.analyze(root) catch {
        printEchoes(sema.diagnostics.getDiagnostics());
        return error.SemanticAnalysisFailed;
    };

    if (sema.diagnostics.getDiagnostics().len > 0) {
        printEchoes(sema.diagnostics.getDiagnostics());
        return error.SemanticAnalysisFailed;
    }
    profiler.record(&profiler.sema_ns);

    var builder = IRBuilder.init(arena, source, &sema.node_types, &sema.model_registry);
    var ir_module = try builder.build(root);
    profiler.record(&profiler.build_ir_ns);

    var has_db = false;
    if (sema.has_server_init) {
        has_db = true;
    } else {
        for (ir_module.functions.items) |func| {
            for (func.instructions.items) |instr| {
                switch (instr.opcode) {
                    .db_get, .db_set, .db_all, .db_where => {
                        has_db = true;
                        break;
                    },
                    else => {},
                }
            }
            if (has_db) break;
        }
    }

    var constant_folder = @import("ir/optimizer.zig").ConstantFolder.init(arena);
    try constant_folder.optimize(&ir_module);

    var cse = @import("ir/optimizer.zig").CommonSubexpressionEliminator.init(arena);
    try cse.optimize(&ir_module);

    var copy_prop = @import("ir/optimizer.zig").CopyPropagator.init(arena);
    try copy_prop.optimize(&ir_module);

    var dce = @import("ir/optimizer.zig").DeadCodeEliminator.init(arena);
    try dce.optimize(&ir_module);
    profiler.record(&profiler.optimize_ns);

    // ── Backend routing ──────────────────────────────────────────────────────
    //
    // Resolve the effective backend: for `auto`, probe the IR and pick
    // native when fully covered, steel otherwise.
    const effective_backend: BackendMode = switch (backend_mode) {
        .steel, .native => backend_mode,
        .auto => blk: {
            if (Capabilities.firstUnsupported(&ir_module)) |reason| {
                NativeDiag.autoFallback(reason);
                break :blk .steel;
            } else {
                break :blk .native;
            }
        },
    };

    var compile_sources = std.ArrayListUnmanaged([]const u8).empty;
    defer compile_sources.deinit(arena);

    // ── Native backend path ───────────────────────────────────────────────────
    if (effective_backend == .native) {
        // If the user asked --backend=native but the IR is out of scope,
        // surface a clear error rather than emitting silent wrong code.
        if (Capabilities.firstUnsupported(&ir_module)) |feature| {
            NativeDiag.unsupportedFeature(feature);
            return error.NativeBackendUnsupported;
        }

        var native_be = NativeBackend.init(arena, session.config, sema.has_server_init);
        try native_be.lower(arena, &ir_module);
        profiler.record(&profiler.gen_c_ns);

        // --emit=mir: dump MIR and exit early.
        if (emit_mode == .mir) {
            const mir_path = try std.mem.concat(arena, u8, &.{ out_bin_path, ".mir" });
            var cwd = std.Io.Dir.cwd();
            var mf = try cwd.createFile(init.io, mir_path, .{ .truncate = true });
            var wb: [8192]u8 = undefined;
            var mw = std.Io.File.Writer.init(mf, init.io, &wb);
            // MirPrinter uses static functions; pass the writer directly.
            try MirPrinter.printModule(&native_be.mir_module.?, &mw.interface);

            try mw.flush();
            mf.close(init.io);
            return out_bin_path;
        }

        // --emit=obj or --emit=exe: write the object file.
        const obj_bytes = try native_be.emitObject(arena);
        const obj_path = try std.mem.concat(arena, u8, &.{ out_bin_path, ".o" });
        var cwd = std.Io.Dir.cwd();
        var obj_file = try cwd.createFile(init.io, obj_path, .{ .truncate = true });
        var wb: [8192]u8 = undefined;
        var fw = std.Io.File.Writer.init(obj_file, init.io, &wb);
        try fw.interface.writeAll(obj_bytes);
        try fw.flush();
        obj_file.close(init.io);

        if (emit_mode == .obj) {
            return obj_path;
        }

        // Write native stub C file to include runtime.h and implement wraps
        const temp_dir = try getOrbitTempDir(init, arena);
        const native_stub_c_path = try std.fs.path.join(arena, &.{ temp_dir, "native_stub.c" });
        var stub_file = try cwd.createFile(init.io, native_stub_c_path, .{ .truncate = true });
        var stub_wb: [1024]u8 = undefined;
        var stub_fw = std.Io.File.Writer.init(stub_file, init.io, &stub_wb);
        try stub_fw.interface.writeAll(
            \\#ifdef ORBIT_WITH_NET
            \\#define orbit_http_query_get original_orbit_http_query_get
            \\#define orbit_response_create original_orbit_response_create
            \\#endif
            \\#define orbit_list_create original_orbit_list_create
            \\#define orbit_map_create original_orbit_map_create
            \\#define orbit_string_slice original_orbit_string_slice
            \\#define orbit_int_to_string original_orbit_int_to_string
            \\#define orbit_float_to_string original_orbit_float_to_string
            \\#define orbit_bool_to_string original_orbit_bool_to_string
            \\#define orbit_string_concat original_orbit_string_concat
            \\#define orbit_string_split original_orbit_string_split
            \\#define orbit_string_replace original_orbit_string_replace
            \\#define orbit_file_read original_orbit_file_read
            \\#define orbit_file_list_dir original_orbit_file_list_dir
            \\#define orbit_os_env original_orbit_os_env
            \\#define orbit_os_exec original_orbit_os_exec
            \\#define orbit_os_argv original_orbit_os_argv
            \\
            \\#include "runtime.h"
            \\
            \\#ifdef ORBIT_WITH_NET
            \\#undef orbit_http_query_get
            \\#undef orbit_response_create
            \\#endif
            \\#undef orbit_list_create
            \\#undef orbit_map_create
            \\#undef orbit_string_slice
            \\#undef orbit_int_to_string
            \\#undef orbit_float_to_string
            \\#undef orbit_bool_to_string
            \\#undef orbit_string_concat
            \\#undef orbit_string_split
            \\#undef orbit_string_replace
            \\#undef orbit_file_read
            \\#undef orbit_file_list_dir
            \\#undef orbit_os_env
            \\#undef orbit_os_exec
            \\#undef orbit_os_argv
            \\
            \\#ifdef __cplusplus
            \\extern "C" {
            \\#endif
            \\
            \\void __main(void) {}
            \\int strcmp(const char* s1, const char* s2) {
            \\    while (*s1 && (*s1 == *s2)) {
            \\        s1++;
            \\        s2++;
            \\    }
            \\    return *(const unsigned char*)s1 - *(const unsigned char*)s2;
            \\}
            \\void* orbit_global_arena = NULL;
            \\extern char** _orbit_argv;
            \\extern int _orbit_argc;
            \\extern int orbit_main(void);
            \\
            \\#ifdef ORBIT_WITH_NET
            \\orbit_string orbit_http_query_get(OrbitRequest* req, orbit_string key) {
            \\    return original_orbit_http_query_get((OrbitArena*)orbit_global_arena, req, key);
            \\}
            \\#endif
            \\OrbitResult orbit_list_create(size_t elem_size, size_t initial_capacity) {
            \\    return original_orbit_list_create((OrbitArena*)orbit_global_arena, elem_size, initial_capacity);
            \\}
            \\OrbitResult orbit_map_create(size_t value_size) {
            \\    return original_orbit_map_create((OrbitArena*)orbit_global_arena, value_size);
            \\}
            \\orbit_string orbit_string_slice(orbit_string s, orbit_int start, orbit_int end) {
            \\    return original_orbit_string_slice((OrbitArena*)orbit_global_arena, s, start, end);
            \\}
            \\orbit_string orbit_int_to_string(orbit_int value) {
            \\    return original_orbit_int_to_string((OrbitArena*)orbit_global_arena, value);
            \\}
            \\orbit_string orbit_float_to_string(orbit_float value) {
            \\    return original_orbit_float_to_string((OrbitArena*)orbit_global_arena, value);
            \\}
            \\orbit_string orbit_bool_to_string(orbit_bool value) {
            \\    return original_orbit_bool_to_string((OrbitArena*)orbit_global_arena, value);
            \\}
            \\orbit_string orbit_string_concat(orbit_string a, orbit_string b) {
            \\    return original_orbit_string_concat((OrbitArena*)orbit_global_arena, a, b);
            \\}
            \\OrbitList* orbit_string_split(orbit_string s, orbit_string delim) {
            \\    return original_orbit_string_split((OrbitArena*)orbit_global_arena, s, delim);
            \\}
            \\orbit_string orbit_string_replace(orbit_string s, orbit_string old_str, orbit_string new_str) {
            \\    return original_orbit_string_replace((OrbitArena*)orbit_global_arena, s, old_str, new_str);
            \\}
            \\OrbitResult orbit_file_read(const char* filename) {
            \\    return original_orbit_file_read((OrbitArena*)orbit_global_arena, filename);
            \\}
            \\OrbitList* orbit_file_list_dir(const char* path) {
            \\    return original_orbit_file_list_dir((OrbitArena*)orbit_global_arena, path);
            \\}
            \\#ifdef ORBIT_WITH_NET
            \\OrbitResponse* orbit_response_create(int status, const char* content_type, const char* body) {
            \\    return original_orbit_response_create((OrbitArena*)orbit_global_arena, status, content_type, body);
            \\}
            \\#endif
            \\orbit_string orbit_os_env(orbit_string var_name) {
            \\    return original_orbit_os_env((OrbitArena*)orbit_global_arena, var_name);
            \\}
            \\orbit_string orbit_os_exec(orbit_string command) {
            \\    return original_orbit_os_exec((OrbitArena*)orbit_global_arena, command);
            \\}
            \\orbit_string orbit_os_argv(orbit_int index) {
            \\    return original_orbit_os_argv((OrbitArena*)orbit_global_arena, index);
            \\}
            \\
            \\#ifdef _WIN32
            \\static void raw_win32_print(const char* s) {
            \\    void* stdout_handle = GetStdHandle(-11); // STD_OUTPUT_HANDLE
            \\    unsigned int len = 0;
            \\    while (s[len]) len++;
            \\    unsigned long written;
            \\    WriteFile(stdout_handle, s, len, &written, NULL);
            \\}
            \\#endif
            \\
            \\#undef print
            \\void print(const char* s) {
            \\#ifdef _WIN32
            \\    raw_win32_print(s);
            \\    raw_win32_print("\r\n");
            \\#else
            \\    printf("%s\n", s);
            \\#endif
            \\}
            \\
            \\#ifdef _WIN32
            \\__declspec(dllimport) char* __stdcall GetCommandLineA(void);
            \\
            \\static void parse_command_line(const char* cmdline, int* argc, char*** argv) {
            \\    int cap = 16;
            \\    *argv = (char**)malloc(cap * sizeof(char*));
            \\    int count = 0;
            \\    const char* p = cmdline;
            \\    while (*p) {
            \\        while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) {
            \\            p++;
            \\        }
            \\        if (!*p) break;
            \\        const char* start = p;
            \\        int in_quotes = 0;
            \\        while (*p) {
            \\            if (*p == '"') {
            \\                in_quotes = !in_quotes;
            \\            } else if (!in_quotes && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) {
            \\                break;
            \\            }
            \\            p++;
            \\        }
            \\        size_t len = p - start;
            \\        char* token = (char*)malloc(len + 1);
            \\        int dest_idx = 0;
            \\        for (size_t i = 0; i < len; i++) {
            \\            if (start[i] != '"') {
            \\                token[dest_idx++] = start[i];
            \\            }
            \\        }
            \\        token[dest_idx] = '\0';
            \\        if (count >= cap) {
            \\            cap *= 2;
            \\            *argv = (char**)realloc(*argv, cap * sizeof(char*));
            \\        }
            \\        (*argv)[count++] = token;
            \\    }
            \\    *argc = count;
            \\}
            \\#endif
            \\
            \\int main(int argc, char* argv[]) {
            \\#ifdef _WIN32
            \\    (void)argc; (void)argv;
            \\    char* cmdline = GetCommandLineA();
            \\    int parsed_argc = 0;
            \\    char** parsed_argv = NULL;
            \\    parse_command_line(cmdline, &parsed_argc, &parsed_argv);
            \\    _orbit_argv = parsed_argv;
            \\    _orbit_argc = parsed_argc;
            \\#else
            \\    _orbit_argv = argv;
            \\    _orbit_argc = argc;
            \\#endif
            \\    orbit_string_pool_init(1024);
            \\    orbit_global_arena = orbit_arena_create(1024 * 1024);
            \\    orbit_main();
            \\    orbit_arena_destroy((OrbitArena*)orbit_global_arena);
            \\    orbit_string_pool_cleanup();
            \\#ifdef _WIN32
            \\    for (int i = 0; i < parsed_argc; i++) {
            \\        free(parsed_argv[i]);
            \\    }
            \\    free(parsed_argv);
            \\#endif
            \\    return 0;
            \\}
            \\
            \\#ifdef __cplusplus
            \\}
            \\#endif
            \\
        );
        try stub_fw.flush();
        stub_file.close(init.io);

        try compile_sources.append(arena, obj_path);
        try compile_sources.append(arena, native_stub_c_path);
    } else {
        // ── Steel (C-backend) path ──────────────────────────────────────────────────
        var backend = CBackend.init(arena, session.config, sema.has_server_init);
        const c_code = try backend.generate(ir_module);
        profiler.record(&profiler.gen_c_ns);

        var cwd = std.Io.Dir.cwd();
        var out_file = try cwd.createFile(init.io, out_c_path, .{ .truncate = true });
        var write_buffer: [8192]u8 = undefined;
        var file_writer_state = std.Io.File.Writer.init(out_file, init.io, &write_buffer);
        try file_writer_state.interface.writeAll(c_code);
        try file_writer_state.flush();
        out_file.close(init.io);
        profiler.record(&profiler.write_files_ns);

        try compile_sources.append(arena, out_c_path);
    }

    const self_exe_dir = std.process.executableDirPathAlloc(init.io, arena) catch ".";

    const sqlite_c_cand_dev = try std.fs.path.join(arena, &.{ self_exe_dir, "../../src/lib/sqlite/sqlite3.c" });
    const sqlite_inc_cand_dev = try std.fs.path.join(arena, &.{ self_exe_dir, "../../src/lib/sqlite" });
    const runtime_inc_cand_dev = try std.fs.path.join(arena, &.{ self_exe_dir, "../../src/runtime" });

    const sqlite_c_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/lib/sqlite/sqlite3.c" });
    const sqlite_inc_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/lib/sqlite" });
    const runtime_inc_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/runtime" });

    var sqlite_c: []const u8 = "src/lib/sqlite/sqlite3.c";
    var sqlite_inc: []const u8 = "-Isrc/lib/sqlite";
    var runtime_inc: []const u8 = "-Isrc/runtime";

    var cand_dev_exists = false;
    var cand_cwd = std.Io.Dir.cwd();
    if (cand_cwd.openFile(init.io, sqlite_c_cand_dev, .{})) |f| {
        f.close(init.io);
        cand_dev_exists = true;
    } else |_| {}

    if (cand_dev_exists) {
        sqlite_c = sqlite_c_cand_dev;
        sqlite_inc = try std.fmt.allocPrint(arena, "-I{s}", .{sqlite_inc_cand_dev});
        runtime_inc = try std.fmt.allocPrint(arena, "-I{s}", .{runtime_inc_cand_dev});
    } else {
        var cand1_exists = false;
        if (cand_cwd.openFile(init.io, sqlite_c_cand1, .{})) |f| {
            f.close(init.io);
            cand1_exists = true;
        } else |_| {}

        if (cand1_exists) {
            sqlite_c = sqlite_c_cand1;
            sqlite_inc = try std.fmt.allocPrint(arena, "-I{s}", .{sqlite_inc_cand1});
            runtime_inc = try std.fmt.allocPrint(arena, "-I{s}", .{runtime_inc_cand1});
        } else {
            const sqlite_c_cand2 = try std.fs.path.join(arena, &.{ self_exe_dir, "src/lib/sqlite/sqlite3.c" });
            const sqlite_inc_cand2 = try std.fs.path.join(arena, &.{ self_exe_dir, "src/lib/sqlite" });
            const runtime_inc_cand2 = try std.fs.path.join(arena, &.{ self_exe_dir, "src/runtime" });

            var cand2_exists = false;
            if (cand_cwd.openFile(init.io, sqlite_c_cand2, .{})) |f| {
                f.close(init.io);
                cand2_exists = true;
            } else |_| {}

            if (cand2_exists) {
                sqlite_c = sqlite_c_cand2;
                sqlite_inc = try std.fmt.allocPrint(arena, "-I{s}", .{sqlite_inc_cand2});
                runtime_inc = try std.fmt.allocPrint(arena, "-I{s}", .{runtime_inc_cand2});
            }
        }
    }

    var sqlite_obj_path: ?[]const u8 = null;
    if (has_db) {
        sqlite_obj_path = try getOrCompileSqliteCache(init, arena, sqlite_c, sqlite_inc, session.verbose, profiler);
    }

    if (linker_mode == .native) {
        const builtin = @import("builtin");
        const obj_ext = if (builtin.os.tag == .windows) ".obj" else ".o";
        
        var obj_paths = std.ArrayListUnmanaged([]const u8).empty;
        defer obj_paths.deinit(arena);
        
        if (effective_backend == .native) {
            const obj_path = compile_sources.items[0];
            const native_stub_c_path = compile_sources.items[1];
            const native_stub_o_path = try std.mem.concat(arena, u8, &.{ native_stub_c_path[0 .. native_stub_c_path.len - 2], obj_ext });
            
            var stub_args = std.ArrayListUnmanaged([]const u8).empty;
            try stub_args.append(arena, "zig");
            try stub_args.append(arena, "cc");
            try stub_args.append(arena, "-c");
            try stub_args.append(arena, native_stub_c_path);
            try stub_args.append(arena, "-o");
            try stub_args.append(arena, native_stub_o_path);
            try stub_args.append(arena, runtime_inc);
            // Suppress GCC stack-protector and UBSan intrinsics so they don't
            // appear as undefined symbols in the native-linked import table.
            try stub_args.append(arena, "-fno-stack-protector");
            try stub_args.append(arena, "-fno-sanitize=all");
            if (sema.has_server_init) {
                try stub_args.append(arena, "-DORBIT_WITH_NET");
            }
            
            if (session.verbose) {
                std.debug.print("[native-linker] Compiling native stub: zig cc -c {s} -o {s} {s}\n", .{ native_stub_c_path, native_stub_o_path, runtime_inc });
            }
            
            var stub_child = try std.process.spawn(init.io, .{
                .argv = stub_args.items,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const stub_status = try stub_child.wait(init.io);
            if (stub_status != .exited or stub_status.exited != 0) {
                return error.StubCompilationFailed;
            }
            
            try obj_paths.append(arena, obj_path);
            try obj_paths.append(arena, native_stub_o_path);
        } else {
            // Steel backend
            const main_c_path = compile_sources.items[0];
            const main_o_path = try std.mem.concat(arena, u8, &.{ main_c_path[0 .. main_c_path.len - 2], obj_ext });
            
            var compile_args = std.ArrayListUnmanaged([]const u8).empty;
            try compile_args.append(arena, "zig");
            try compile_args.append(arena, "cc");
            try compile_args.append(arena, "-c");
            try compile_args.append(arena, main_c_path);
            try compile_args.append(arena, "-o");
            try compile_args.append(arena, main_o_path);
            try compile_args.append(arena, runtime_inc);
            // Suppress GCC intrinsics for native linker path.
            try compile_args.append(arena, "-fno-stack-protector");
            try compile_args.append(arena, "-fno-sanitize=all");
            if (has_db) {
                try compile_args.append(arena, sqlite_inc);
            }
            if (sema.has_server_init) {
                try compile_args.append(arena, "-DORBIT_WITH_NET");
            }
            
            if (session.verbose) {
                std.debug.print("[native-linker] Compiling steel source: zig cc -c {s} -o {s}\n", .{ main_c_path, main_o_path });
            }
            
            var comp_child = try std.process.spawn(init.io, .{
                .argv = compile_args.items,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const comp_status = try comp_child.wait(init.io);
            if (comp_status != .exited or comp_status.exited != 0) {
                return error.SteelObjectCompilationFailed;
            }
            
            try obj_paths.append(arena, main_o_path);
        }
        
        if (has_db) {
            try obj_paths.append(arena, sqlite_obj_path.?);
        }
        
        const native_link = @import("backend/link/mod.zig");
        const format: native_link.Format = if (builtin.os.tag == .windows) .coff else .elf;
        
        if (session.verbose) {
            std.debug.print("[native-linker] Linking binary: {s} format={s} entry=main\n", .{ out_bin_path, @tagName(format) });
            for (obj_paths.items) |op| {
                std.debug.print("  object: {s}\n", .{op});
            }
        }
        
        try native_link.link(
            arena,
            init.io,
            format,
            out_bin_path,
            obj_paths.items,
            &[_][]const u8{},
            "main",
        );
        
        // Clean up temp objects
        if (effective_backend == .native) {
            std.Io.Dir.deleteFileAbsolute(init.io, obj_paths.items[1]) catch {};
        } else {
            std.Io.Dir.deleteFileAbsolute(init.io, obj_paths.items[0]) catch {};
        }
        
        profiler.record(&profiler.compile_app_ns);
        profiler.linking_ns = 0;
        return out_bin_path;
    }

    if (session.verbose) {
        std.debug.print("Invoking zig cc -O3...\n", .{});
    }

    var args_list = std.ArrayListUnmanaged([]const u8).empty;
    try args_list.append(arena, "zig");
    try args_list.append(arena, "cc");
    for (compile_sources.items) |src| {
        try args_list.append(arena, src);
    }
    if (has_db) {
        try args_list.append(arena, sqlite_obj_path.?);
        try args_list.append(arena, "-DORBIT_WITH_DB");
    }
    try args_list.append(arena, "-o");
    try args_list.append(arena, out_bin_path);
    try args_list.append(arena, "-O3");
    try args_list.append(arena, "-s");
    if (has_db) {
        try args_list.append(arena, sqlite_inc);
    }
    try args_list.append(arena, runtime_inc);
    if (sema.has_server_init) {
        try args_list.append(arena, "-DORBIT_WITH_NET");
        const builtin = @import("builtin");
        if (builtin.os.tag == .windows) {
            try args_list.append(arena, "-lws2_32");
        }
    }

    if (session.verbose) {
        var arg_str = std.ArrayListUnmanaged(u8).empty;
        for (args_list.items) |arg| {
            try arg_str.appendSlice(arena, arg);
            try arg_str.append(arena, ' ');
        }
        std.debug.print("Native link command: {s}\n", .{arg_str.items});
    }

    var child = try std.process.spawn(init.io, .{
        .argv = args_list.items,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term_status = try child.wait(init.io);
    profiler.record(&profiler.compile_app_ns);
    profiler.linking_ns = 0;

    if (term_status == .exited and term_status.exited == 0) {
        return out_bin_path;
    } else {
        std.debug.print("Compilation failed.\n", .{});
        return error.NativeCompilationFailed;
    }
}

fn runBootstrapMode(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var clean = false;
    var verify = false;
    var max_stage: u32 = 3;
    var use_native_linker = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--clean")) clean = true;
        if (std.mem.eql(u8, arg, "--verify")) verify = true;
        if (std.mem.eql(u8, arg, "--linker=native")) use_native_linker = true;
        if (std.mem.startsWith(u8, arg, "--stage=")) {
            const stage_str = arg["--stage=".len..];
            max_stage = std.fmt.parseInt(u32, stage_str, 10) catch 3;
        }
    }

    var cwd = std.Io.Dir.cwd();

    if (clean) {
        std.debug.print("[bootstrap] Cleaning bootstrap artifacts...\n", .{});
        cwd.deleteFile(init.io, "compiler/selfhost/stage1.exe") catch {};
        cwd.deleteFile(init.io, "compiler/selfhost/stage2.exe") catch {};
        cwd.deleteFile(init.io, "compiler/selfhost/stage3.exe") catch {};
        cwd.deleteFile(init.io, "compiler/selfhost/stage1.o") catch {};
        cwd.deleteFile(init.io, "compiler/selfhost/stage2.o") catch {};
        cwd.deleteFile(init.io, "compiler/selfhost/stage3.o") catch {};
        std.debug.print("[bootstrap] Clean completed.\n", .{});
        return;
    }

    // Ensure compiler/selfhost directory exists
    cwd.createDirPath(init.io, "compiler/selfhost") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const self_path = try std.fs.path.resolve(arena, &.{args[0]});
    try init.environ_map.put("ORBIT_HOST_COMPILER", self_path);

    if (max_stage >= 1) {
        std.debug.print("[bootstrap] Building Stage 1 compiler using {s}...\n", .{self_path});
        var cmd = std.ArrayListUnmanaged([]const u8).empty;
        try cmd.append(arena, self_path);
        try cmd.append(arena, "build");
        try cmd.append(arena, "compiler/main.orb");
        try cmd.append(arena, "-o");
        try cmd.append(arena, "compiler/selfhost/stage1.exe");
        try cmd.append(arena, "--backend=steel");
        if (use_native_linker) {
            try cmd.append(arena, "--linker=native");
        }

        var child = try std.process.spawn(init.io, .{ .argv = cmd.items, .environ_map = init.environ_map });
        const term_res = try child.wait(init.io);
        if (term_res != .exited or term_res.exited != 0) {
            std.debug.print("[bootstrap] Failed to build Stage 1 compiler.\n", .{});
            return error.BootstrapStage1Failed;
        }
        std.debug.print("[bootstrap] Stage 1 compiler built successfully: compiler/selfhost/stage1.exe\n", .{});
    }

    if (max_stage >= 2) {
        const stage1_path = try std.fs.path.resolve(arena, &.{"compiler/selfhost/stage1.exe"});
        std.debug.print("[bootstrap] Building Stage 2 compiler using {s}...\n", .{stage1_path});
        var cmd = std.ArrayListUnmanaged([]const u8).empty;
        try cmd.append(arena, stage1_path);
        try cmd.append(arena, "build");
        try cmd.append(arena, "compiler/main.orb");
        try cmd.append(arena, "-o");
        try cmd.append(arena, "compiler/selfhost/stage2.exe");
        try cmd.append(arena, "--backend=steel");
        if (use_native_linker) {
            try cmd.append(arena, "--linker=native");
        }

        var child = try std.process.spawn(init.io, .{ .argv = cmd.items, .environ_map = init.environ_map });
        const term_res = try child.wait(init.io);
        if (term_res != .exited or term_res.exited != 0) {
            std.debug.print("[bootstrap] Failed to build Stage 2 compiler.\n", .{});
            return error.BootstrapStage2Failed;
        }
        std.debug.print("[bootstrap] Stage 2 compiler built successfully: compiler/selfhost/stage2.exe\n", .{});
    }

    if (max_stage >= 3) {
        const stage2_path = try std.fs.path.resolve(arena, &.{"compiler/selfhost/stage2.exe"});
        std.debug.print("[bootstrap] Building Stage 3 compiler using {s}...\n", .{stage2_path});
        var cmd = std.ArrayListUnmanaged([]const u8).empty;
        try cmd.append(arena, stage2_path);
        try cmd.append(arena, "build");
        try cmd.append(arena, "compiler/main.orb");
        try cmd.append(arena, "-o");
        try cmd.append(arena, "compiler/selfhost/stage3.exe");
        try cmd.append(arena, "--backend=steel");
        if (use_native_linker) {
            try cmd.append(arena, "--linker=native");
        }

        var child = try std.process.spawn(init.io, .{ .argv = cmd.items, .environ_map = init.environ_map });
        const term_res = try child.wait(init.io);
        if (term_res != .exited or term_res.exited != 0) {
            std.debug.print("[bootstrap] Failed to build Stage 3 compiler.\n", .{});
            return error.BootstrapStage3Failed;
        }
        std.debug.print("[bootstrap] Stage 3 compiler built successfully: compiler/selfhost/stage3.exe\n", .{});
    }

    if (verify and max_stage >= 3) {
        std.debug.print("[bootstrap] Verifying fixed-point reproducibility...\n", .{});
        const f2 = try cwd.openFile(init.io, "compiler/selfhost/stage2.exe", .{});
        defer f2.close(init.io);
        const f3 = try cwd.openFile(init.io, "compiler/selfhost/stage3.exe", .{});
        defer f3.close(init.io);

        const len2 = try f2.length(init.io);
        const len3 = try f3.length(init.io);

        if (len2 != len3) {
            std.debug.print("[bootstrap] Verification FAILED: sizes differ ({d} vs {d} bytes).\n", .{ len2, len3 });
            return error.BootstrapVerificationFailed;
        }

        const b2 = try arena.alloc(u8, len2);
        const b3 = try arena.alloc(u8, len3);

        var r2_buf: [8192]u8 = undefined;
        var r2 = std.Io.File.Reader.init(f2, init.io, &r2_buf);
        try r2.interface.readSliceAll(b2);

        var r3_buf: [8192]u8 = undefined;
        var r3 = std.Io.File.Reader.init(f3, init.io, &r3_buf);
        try r3.interface.readSliceAll(b3);

        if (!std.mem.eql(u8, b2, b3)) {
            std.debug.print("[bootstrap] Verification FAILED: byte contents differ.\n", .{});
            return error.BootstrapVerificationFailed;
        }

        std.debug.print("[bootstrap] SUCCESS: Stage 2 and Stage 3 are byte-identical! Fixed-point verified.\n", .{});
    }
}

fn runBuildMode(
    init: std.process.Init,
    file_path: []const u8,
    debug: bool,
    no_kynx: bool,
    verbose: bool,
    timings: bool,
    timings_json: bool,
    config: AtlasConfig,
    backend_mode: BackendMode,
    emit_mode: EmitMode,
    output_override: ?[]const u8,
    linker_mode: LinkerMode,
) !void {
    const arena = init.arena.allocator();

    var session = try CompilationSession.init(init, file_path, no_kynx, debug, verbose, timings, timings_json, config);
    defer session.deinit();

    const temp_dir = try getOrbitTempDir(init, arena);
    const temp_c_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_build.c" });
    const out_bin_name = if (output_override) |out|
        out
    else
        try std.fmt.allocPrint(arena, "{s}.exe", .{config.output_name});

    var use_cache = false;
    const cb_path = try getCachePath(init, arena, file_path, session.project_hash);

    if (config.cache and output_override == null) {
        var cwd = std.Io.Dir.cwd();
        if (cwd.openFile(init.io, cb_path, .{})) |f| {
            f.close(init.io);
            use_cache = true;
            try copyFile(init.io, arena, cb_path, out_bin_name);
            session.profiler.record(&session.profiler.cache_lookup_ns);
        } else |_| {}
    }

    // Create the spinner in its final stack location FIRST, then spawn the
    // thread — this prevents the dangling-pointer bug that occurred when
    // Spinner.start() returned by value after passing &self to the thread.
    var spinner = term.layout.Spinner.init("Compiling...");
    spinner.spawn() catch {};

    if (!use_cache) {
        const actual_out_path = try compileToBinary(init, &session, cb_path, temp_c_path, backend_mode, emit_mode, linker_mode);
        std.Io.Dir.deleteFileAbsolute(init.io, temp_c_path) catch {};
        try copyFile(init.io, arena, actual_out_path, out_bin_name);
    }

    spinner.stop();

    const elapsed_s = session.profiler.timer.readSeconds();
    session.profiler.total_ns = @intFromFloat(elapsed_s * 1_000_000_000.0);

    if (session.timings) {
        session.profiler.printTimings(session.timings_json);
    }

    if (!session.timings_json) {
        const check = term.symbols.get(.check);
        const green = term.style.getEsc(.bold_success);
        const white = term.style.getEsc(.bold_white);
        const reset = term.style.getReset();

        var l1: [128]u8 = undefined;
        const line1 = std.fmt.bufPrint(&l1, "{s}{s}{s} Modules      {d} source modules resolved", .{ green, check, reset, session.compiler.units.items.len }) catch "";

        var l2: [128]u8 = undefined;
        const line2 = std.fmt.bufPrint(&l2, "{s}{s}{s} Semantic     0 errors, 0 warnings", .{ green, check, reset }) catch "";

        var l3: [256]u8 = undefined;
        const backend_name = if (backend_mode == .steel) "Steel C Engine" else "Direct Native CodeGen";
        const line3 = std.fmt.bufPrint(&l3, "{s}{s}{s} Target       {s}", .{ green, check, reset, backend_name }) catch "";

        var l4: [256]u8 = undefined;
        const line4 = std.fmt.bufPrint(&l4, "{s}{s}{s} Output       {s}{s}{s}", .{ green, check, reset, white, out_bin_name, reset }) catch "";

        var l5: [128]u8 = undefined;
        const line5 = std.fmt.bufPrint(&l5, "{s}{s}{s} Duration     {d:.0} ms", .{ green, check, reset, @as(f64, @floatFromInt(session.profiler.total_ns)) / 1_000_000.0 }) catch "";

        var title_buf: [512]u8 = undefined;
        const title = term.layout.renderGradientTextBuf(&title_buf, "Orbit build complete", .{ 0, 229, 255 }, .{ 0, 176, 255 });

        // Build kynx footer only when Kynx verification is active
        const maybe_kynx: []const u8 = if (!no_kynx) blk: {
            var kynx_buf: [512]u8 = undefined;
            break :blk term.layout.renderGradientTextBuf(&kynx_buf, "Secured by Kynx", .{ 96, 165, 250 }, .{ 30, 58, 138 });
        } else "";

        var card_lines_buf: [8][]const u8 = undefined;
        var n_lines: usize = 5;
        card_lines_buf[0] = line1;
        card_lines_buf[1] = line2;
        card_lines_buf[2] = line3;
        card_lines_buf[3] = line4;
        card_lines_buf[4] = line5;
        if (!no_kynx) {
            card_lines_buf[5] = "";
            card_lines_buf[6] = maybe_kynx;
            n_lines = 7;
        }

        term.layout.renderBoxCardStderr(title, card_lines_buf[0..n_lines], 64);
    }
}

fn runExecuteMode(
    init: std.process.Init,
    file_path: []const u8,
    debug: bool,
    no_kynx: bool,
    verbose: bool,
    timings: bool,
    timings_json: bool,
    config: AtlasConfig,
    backend_mode: BackendMode,
    emit_mode: EmitMode,
    linker_mode: LinkerMode,
) !void {
    const arena = init.arena.allocator();

    var session = try CompilationSession.init(init, file_path, no_kynx, debug, verbose, timings, timings_json, config);
    defer session.deinit();

    var bin_path_to_run: []const u8 = "";
    var use_cache = false;
    const cb_path = try getCachePath(init, arena, file_path, session.project_hash);
    const cb_c_path = try getCacheCPath(arena, cb_path);

    if (config.cache) {
        var cwd = std.Io.Dir.cwd();
        if (cwd.openFile(init.io, cb_path, .{})) |f| {
            f.close(init.io);
            use_cache = true;
            bin_path_to_run = cb_path;
            session.profiler.record(&session.profiler.cache_lookup_ns);
        } else |_| {}
    }

    if (!use_cache) {
        const built_bin_path = try compileToBinary(init, &session, cb_path, cb_c_path, backend_mode, emit_mode, linker_mode);
        std.Io.Dir.deleteFileAbsolute(init.io, cb_c_path) catch {};
        bin_path_to_run = built_bin_path;
    }

    const elapsed_s = session.profiler.timer.readSeconds();
    session.profiler.total_ns = @intFromFloat(elapsed_s * 1_000_000_000.0);

    if (session.timings) {
        session.profiler.printTimings(session.timings_json);
    }

    const raw_args = try init.minimal.args.toSlice(arena);
    var forward_args = std.ArrayListUnmanaged([]const u8).empty;
    try forward_args.append(arena, bin_path_to_run);

    for (raw_args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "--no-kynx") or std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "--timings") or std.mem.eql(u8, arg, "--timings=json")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--color=") or std.mem.startsWith(u8, arg, "--unicode=")) {
            continue;
        }
        try forward_args.append(arena, arg);
    }

    var child = try std.process.spawn(init.io, .{ .argv = forward_args.items });
    const term_status = try child.wait(init.io);

    if (term_status != .exited or term_status.exited != 0) {
        const code: i64 = if (term_status == .exited) @intCast(term_status.exited) else -1;
        std.debug.print("\n  [orbit] process exited with code {d}\n", .{code});
        return error.OrbitRunFailed;
    }
}

fn runTestMode(
    init: std.process.Init,
    file_path: []const u8,
    debug: bool,
    no_kynx: bool,
    verbose: bool,
    timings: bool,
    timings_json: bool,
    config: AtlasConfig,
    backend_mode: BackendMode,
    emit_mode: EmitMode,
    linker_mode: LinkerMode,
) !void {
    const arena = init.arena.allocator();

    var session = try CompilationSession.init(init, file_path, no_kynx, debug, verbose, timings, timings_json, config);
    defer session.deinit();

    const temp_dir = try getOrbitTempDir(init, arena);
    const test_bin_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_test.exe" });
    const test_c_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_test.c" });

    _ = try compileToBinary(init, &session, test_bin_path, test_c_path, backend_mode, emit_mode, linker_mode);
    std.Io.Dir.deleteFileAbsolute(init.io, test_c_path) catch {};

    if (session.timings) {
        const elapsed_s = session.profiler.timer.readSeconds();
        session.profiler.total_ns = @intFromFloat(elapsed_s * 1_000_000_000.0);
        session.profiler.printTimings(session.timings_json);
    }

    std.debug.print("\n  [orbit test] running {s}\n\n", .{test_bin_path});

    var child = try std.process.spawn(init.io, .{ .argv = &[_][]const u8{test_bin_path} });
    const term_status = try child.wait(init.io);

    std.Io.Dir.deleteFileAbsolute(init.io, test_bin_path) catch {};

    if (term_status == .exited and term_status.exited == 0) {
        std.debug.print("\n  \u{2705} [orbit test] PASS ({s})\n", .{file_path});
    } else {
        const code: i64 = if (term_status == .exited) @intCast(term_status.exited) else -1;
        std.debug.print("\n  \u{274C} [orbit test] FAIL ({s}) exit={d}\n", .{ file_path, code });
        return error.OrbitTestFailed;
    }
}

fn reportSyntaxError(tok: anytype) void {
    const path = if (tok.file_path.len > 0) tok.file_path else "<unknown>";
    const src = tok.file_source;

    var snippet: []const u8 = "";
    var line_count: usize = 1;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line_count == tok.loc.line) {
            snippet = line;
            break;
        }
        line_count += 1;
    }

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Unexpected token '{s}'", .{@tagName(tok.tag)}) catch "Syntax Error";

    term.layout.renderErrorCardStderr("E0001", msg, path, tok.loc.line, tok.loc.col, snippet, "Check syntax rules around this token.", 68);
}

fn printEchoes(diagnostics: []const Sema.Diagnostic) void {
    for (diagnostics) |diag| {
        const src = if (diag.file_source.len > 0) diag.file_source else "";
        const path = if (diag.file_path.len > 0) diag.file_path else "<unknown>";

        var snippet: []const u8 = "";
        var line_count: usize = 1;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (line_count == diag.line) {
                snippet = line;
                break;
            }
            line_count += 1;
        }

        term.layout.renderErrorCardStderr(diag.code, diag.message, path, diag.line, diag.col, snippet, "Ensure type consistency and scope rules are satisfied.", 68);
    }
}

const OrbitTimer = struct {
    start_timestamp: std.Io.Clock.Timestamp,

    fn start() OrbitTimer {
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{
            .start_timestamp = std.Io.Clock.Timestamp.now(io, .awake) catch @panic("a monotonic clock is not supported on this platform"),
        };
    }

    fn readSeconds(self: *OrbitTimer) f64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const now = std.Io.Clock.Timestamp.now(io, .awake) catch @panic("a monotonic clock is not supported on this platform");
        const elapsed = self.start_timestamp.durationTo(now);
        return @as(f64, @floatFromInt(elapsed.raw.nanoseconds)) / 1_000_000_000.0;
    }

    fn reset(self: *OrbitTimer) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.start_timestamp = std.Io.Clock.Timestamp.now(io, .awake) catch @panic("a monotonic clock is not supported on this platform");
    }
};

fn getOrbitCacheDir(init: std.process.Init, arena: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (init.environ_map.get(home_env)) |home| {
        const cache_dir = try std.fs.path.join(arena, &.{ home, ".orbit", "cache" });
        std.Io.Dir.cwd().createDirPath(init.io, cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return cache_dir;
    } else {
        return ".";
    }
}

fn getOrbitTempDir(init: std.process.Init, arena: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    const temp_env = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
    if (init.environ_map.get(temp_env)) |temp| {
        const orbit_temp = try std.fs.path.join(arena, &.{ temp, "orbit" });
        std.Io.Dir.cwd().createDirPath(init.io, orbit_temp) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return orbit_temp;
    } else {
        const fallback = if (builtin.os.tag == .windows) "C:\\Windows\\Temp\\orbit" else "/tmp/orbit";
        std.Io.Dir.cwd().createDirPath(init.io, fallback) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return fallback;
    }
}

fn getCachePath(init: std.process.Init, arena: std.mem.Allocator, file_path: []const u8, source_hash: u64) ![]const u8 {
    var sanitised = try arena.alloc(u8, file_path.len);
    for (file_path, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c)) {
            sanitised[i] = c;
        } else {
            sanitised[i] = '_';
        }
    }
    const cache_dir = try getOrbitCacheDir(init, arena);
    const cache_bin_name = try std.fmt.allocPrint(arena, "cache_{s}_{d}.exe", .{ sanitised, source_hash });
    return try std.fs.path.join(arena, &.{ cache_dir, cache_bin_name });
}

fn getCacheCPath(arena: std.mem.Allocator, bin_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, bin_path, ".exe")) {
        return try std.fmt.allocPrint(arena, "{s}.c", .{bin_path[0 .. bin_path.len - 4]});
    }
    return try std.fmt.allocPrint(arena, "{s}.c", .{bin_path});
}

fn fnv1a(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (data) |byte| {
        hash ^= byte;
        hash = hash *% 1099511628211;
    }
    return hash;
}

fn fnv1a_combine(current_hash: u64, data: []const u8) u64 {
    var hash = current_hash;
    for (data) |byte| {
        hash ^= byte;
        hash = hash *% 1099511628211;
    }
    return hash;
}

fn readSourceFile(allocator: std.mem.Allocator, io: anytype, file_path: []const u8) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    const source = try allocator.alloc(u8, file_len);

    var read_buffer: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &read_buffer);
    try reader.interface.readSliceAll(source);
    return source;
}

fn copyFile(io: anytype, allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    var src_file = try cwd.openFile(io, src, .{});
    defer src_file.close(io);
    const len = try src_file.length(io);
    const buffer = try allocator.alloc(u8, len);
    defer allocator.free(buffer);

    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(src_file, io, &read_buf);
    try reader.interface.readSliceAll(buffer);

    cwd.deleteFile(io, dest) catch {};
    var dest_file = cwd.createFile(io, dest, .{ .truncate = true }) catch |err| blk: {
        if (err == error.AccessDenied) {
            cwd.deleteFile(io, dest) catch {};
            break :blk try cwd.createFile(io, dest, .{ .truncate = true });
        }
        return err;
    };
    defer dest_file.close(io);
    var write_buf: [8192]u8 = undefined;
    var writer = std.Io.File.Writer.init(dest_file, io, &write_buf);
    try writer.interface.writeAll(buffer);
    try writer.flush();
}
