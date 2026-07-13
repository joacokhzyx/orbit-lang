const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const Compiler = @import("compiler.zig").Compiler;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const CBackend = @import("codegen/c_backend.zig").CBackend;
const AtlasConfig = @import("atlas.zig").AtlasConfig;
const term = @import("terminal/terminal.zig");

const ORBIT_VERSION = "0.1.0-rc.1";

pub const CompilationProfiler = struct {
    timer: OrbitTimer,
    io: @TypeOf(@as(std.process.Init, undefined).io),
    
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
    
    pub fn start(io: anytype) !CompilationProfiler {
        return .{
            .timer = try OrbitTimer.start(io),
            .io = io,
        };
    }
    
    pub fn record(self: *CompilationProfiler, ns_field: *u64) void {
        const elapsed_s = self.timer.readSeconds();
        ns_field.* = @intFromFloat(elapsed_s * 1_000_000_000.0);
        // Reset timer
        if (comptime @hasDecl(std.time, "Timer")) {
            self.timer.impl.reset();
        } else {
            self.timer.impl = std.Io.Clock.awake.now(self.io);
        }
    }

    pub fn printTimings(self: *CompilationProfiler, json_mode: bool) void {
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
            std.debug.print("Native compilation    {d:.2} ms\n", .{@as(f64, @floatFromInt(self.compile_app_ns)) / 1_000_000.0});
            std.debug.print("Linking               {d:.2} ms\n", .{@as(f64, @floatFromInt(self.linking_ns)) / 1_000_000.0});
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
        var profiler = try CompilationProfiler.start(init_ctx.io);
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

    if (args.len < 3) {
        printHelp();
        return;
    }

    const command = args[1];
    const file_path = args[2];
    const config = AtlasConfig.load(arena, init.io) catch AtlasConfig{};
    
    var debug = false;
    var no_kynx = config.no_kynx;
    var verbose = false;
    var timings = false;
    var timings_json = false;
    var color_pref = term.ColorPreference.auto;
    var unicode_pref = term.UnicodePreference.auto;

    for (args) |arg| {
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
    }

    _ = term.init(color_pref, unicode_pref, init.io, init.environ_map);

    if (std.mem.eql(u8, command, "dev") or std.mem.eql(u8, command, "run")) {
        try runExecuteMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuildMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config);
    } else if (std.mem.eql(u8, command, "test")) {
        try runTestMode(init, file_path, debug, no_kynx, verbose, timings, timings_json, config);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    std.debug.print(
        \\
        \\  ⏣ Orbit  - v{s}
        \\
        \\  Usage: orbit <command> <file.orb> [options]
        \\
        \\  Commands:
        \\    dev      Compile + run (alias de 'run')
        \\    run      Compile + run and propagate exit code
        \\    build    Compile to native optimized binary
        \\    test     Compile + run, PASS if exit code is 0
        \\
        \\  Options:
        \\    --debug          Enable verbose runtime logs
        \\    --no-kynx        Disable Kynx autonomous protection
        \\    --verbose        Print internal compiler details and tool invocations
        \\    --timings        Show phase-by-phase compilation profiles
        \\    --timings=json   Show phase compilation profiles in JSON format
        \\    --color=MODE     auto, always, never
        \\    --unicode=MODE   auto, always, never
        \\
    , .{ORBIT_VERSION});
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
        var sqlite_timer = try OrbitTimer.start(init.io);
        
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
            std.debug.print("Executing: zig cc -c {s} -o {s} -O3 {s}\n", .{sqlite_c, cache_obj_path, sqlite_inc_dir});
        }
        var child = try std.process.spawn(init.io, .{ .argv = sqlite_args.items });
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

    if (session.verbose) {
        std.debug.print("Invoking zig cc -O3...\n", .{});
    }

    var args_list = std.ArrayListUnmanaged([]const u8).empty;
    try args_list.append(arena, "zig");
    try args_list.append(arena, "cc");
    try args_list.append(arena, out_c_path);
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

fn runBuildMode(
    init: std.process.Init,
    file_path: []const u8,
    debug: bool,
    no_kynx: bool,
    verbose: bool,
    timings: bool,
    timings_json: bool,
    config: AtlasConfig,
) !void {
    const arena = init.arena.allocator();
    
    var session = try CompilationSession.init(init, file_path, no_kynx, debug, verbose, timings, timings_json, config);
    defer session.deinit();

    const temp_dir = try getOrbitTempDir(init, arena);
    const temp_c_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_build.c" });
    const out_bin_name = try std.fmt.allocPrint(arena, "{s}.exe", .{config.output_name});
    
    var use_cache = false;
    const cb_path = try getCachePath(init, arena, file_path, session.project_hash);
    
    if (config.cache) {
        var cwd = std.Io.Dir.cwd();
        if (cwd.openFile(init.io, cb_path, .{})) |f| {
            f.close(init.io);
            use_cache = true;
            try copyFile(init.io, arena, cb_path, out_bin_name);
            session.profiler.record(&session.profiler.cache_lookup_ns);
        } else |_| {}
    }
    
    if (!use_cache) {
        _ = try compileToBinary(init, &session, cb_path, temp_c_path);
        std.Io.Dir.deleteFileAbsolute(init.io, temp_c_path) catch {};
        try copyFile(init.io, arena, cb_path, out_bin_name);
    }
    
    const elapsed_s = session.profiler.timer.readSeconds();
    session.profiler.total_ns = @intFromFloat(elapsed_s * 1_000_000_000.0);
    
    if (session.timings) {
        session.profiler.printTimings(session.timings_json);
    }
    
    if (!session.timings_json) {
        const orbit_sym = term.symbols.get(.orbit);
        const accent_esc = term.style.getEsc(.accent);
        const reset = term.style.getReset();
        
        std.debug.print("  {s} {s}Orbit{s}\n", .{ orbit_sym, accent_esc, reset });
        std.debug.print("    Resolving    {d} modules\n", .{session.compiler.units.items.len});
        std.debug.print("    Checking     complete\n", .{});
        std.debug.print("    Emitting     native binary\n", .{});
        std.debug.print("    Output       {s}\n", .{out_bin_name});
        std.debug.print("    Duration     {d:.0} ms\n\n", .{@as(f64, @floatFromInt(session.profiler.total_ns)) / 1_000_000.0});
        
        if (!no_kynx) {
            const bold_green = if (term.capabilities.get().has_color) "\x1b[1;32m" else "";
            std.debug.print("{s}Secured by Kynx.{s}\n", .{ bold_green, reset });
        }
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
        const built_bin_path = try compileToBinary(init, &session, cb_path, cb_c_path);
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
) !void {
    const arena = init.arena.allocator();
    
    var session = try CompilationSession.init(init, file_path, no_kynx, debug, verbose, timings, timings_json, config);
    defer session.deinit();

    const temp_dir = try getOrbitTempDir(init, arena);
    const test_bin_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_test.exe" });
    const test_c_path = try std.fs.path.join(arena, &.{ temp_dir, "temp_test.c" });

    _ = try compileToBinary(init, &session, test_bin_path, test_c_path);
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
    std.debug.print("\n ⏣ Orbit v{s}  failed to start\n\n", .{ORBIT_VERSION});
    std.debug.print("  [SYNTAX ERROR] unexpectedly found '{s}'\n", .{@tagName(tok.tag)});
    std.debug.print("\n  file: {s}:{d}\n", .{ path, tok.loc.line });
    var line_count: usize = 1;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (line_count == tok.loc.line) {
            std.debug.print("    {d} | {s}\n", .{line_count, line});
            std.debug.print("      | ", .{});
            var i: usize = 1;
            while (i < tok.loc.col) : (i += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("^-- here\n", .{});
            break;
        }
        line_count += 1;
    }
}

fn printEchoes(diagnostics: []const Sema.Diagnostic) void {
    std.debug.print("\n⏣ Orbit echo: Consistency Resonant Failures\n", .{});
    std.debug.print("  ------------------------------------------\n", .{});

    for (diagnostics) |diag| {
        const src = if (diag.file_source.len > 0) diag.file_source else "";
        const path = if (diag.file_path.len > 0) diag.file_path else "<unknown>";
        std.debug.print("\n  [ {s} ] {s}\n", .{diag.code, diag.message});
        std.debug.print("  at {s}:{d}:{d}\n\n", .{path, diag.line, diag.col});

        var line_count: usize = 1;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (line_count == diag.line) {
                std.debug.print("    {d} | {s}\n", .{line_count, line});
                std.debug.print("      | ", .{});
                var i: usize = 1;
                while (i < diag.col) : (i += 1) {
                    std.debug.print(" ", .{});
                }
                std.debug.print("^-- here\n", .{});
                break;
            }
            line_count += 1;
        }
    }
    std.debug.print("\n  The system cannot maintain gravity. Fix the echoes above.\n\n", .{});
}

const OrbitTimer = struct {
    impl: if (@hasDecl(std.time, "Timer")) std.time.Timer else std.Io.Timestamp,
    io: @TypeOf(@as(std.process.Init, undefined).io),

    fn start(io: @TypeOf(@as(std.process.Init, undefined).io)) !OrbitTimer {
        if (comptime @hasDecl(std.time, "Timer")) {
            return OrbitTimer{
                .impl = try std.time.Timer.start(),
                .io = io,
            };
        } else {
            return OrbitTimer{
                .impl = std.Io.Clock.awake.now(io),
                .io = io,
            };
        }
    }

    fn readSeconds(self: *OrbitTimer) f64 {
        if (comptime @hasDecl(std.time, "Timer")) {
            return @as(f64, @floatFromInt(self.impl.read())) / 1_000_000_000.0;
        } else {
            const elapsed = self.impl.untilNow(self.io, .awake);
            return @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1_000_000_000.0;
        }
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
        return try std.fmt.allocPrint(arena, "{s}.c", .{bin_path[0..bin_path.len - 4]});
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
    
    var dest_file = try cwd.createFile(io, dest, .{ .truncate = true });
    defer dest_file.close(io);
    var write_buf: [8192]u8 = undefined;
    var writer = std.Io.File.Writer.init(dest_file, io, &write_buf);
    try writer.interface.writeAll(buffer);
    try writer.flush();
}
