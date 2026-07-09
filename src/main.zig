const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const Compiler = @import("compiler.zig").Compiler;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const CBackend = @import("codegen/c_backend.zig").CBackend;
const AtlasConfig = @import("atlas.zig").AtlasConfig;

const ORBIT_VERSION = "0.1.0-rc.1";

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
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
        if (std.mem.eql(u8, arg, "--no-kynx")) no_kynx = true;
    }

    if (std.mem.eql(u8, command, "dev") or std.mem.eql(u8, command, "run")) {
        try runExecuteMode(init, file_path, debug, no_kynx, config);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuildMode(init, file_path, debug, no_kynx, config);
    } else if (std.mem.eql(u8, command, "test")) {
        try runTestMode(init, file_path, debug, no_kynx, config);
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
        \\    --debug    Enable verbose runtime logs
        \\    --no-kynx  Disable Kynx autonomous protection
        \\
    , .{ORBIT_VERSION});
}

fn compileToBinary(init: std.process.Init, file_path: []const u8, no_kynx: bool, config: AtlasConfig) ![]const u8 {
    _ = no_kynx;
    const arena = init.arena.allocator();
    var timer = try OrbitTimer.start(init.io);

    var compiler = Compiler.init(arena);
    defer compiler.deinit();
    try compiler.loadEntry(init.io, file_path);

    const root = try compiler.mergedRoots();
    const source = try compiler.mergedSource();

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

    var builder = IRBuilder.init(arena, source, &sema.node_types, &sema.model_registry);
    const ir_module = try builder.build(root);

    var backend = CBackend.init(arena, config, sema.has_server_init);
    const c_code = try backend.generate(ir_module);

    const out_c_path = "orbit.c";
    const out_bin_name = try std.fmt.allocPrint(arena, "{s}.exe", .{config.output_name});

    var cwd = std.Io.Dir.cwd();
    var out_file = try cwd.createFile(init.io, out_c_path, .{ .truncate = true });
    var write_buffer: [8192]u8 = undefined;
    var file_writer_state = std.Io.File.Writer.init(out_file, init.io, &write_buffer);
    try file_writer_state.interface.writeAll(c_code);
    try file_writer_state.flush();
    out_file.close(init.io);

    // Resolve installation paths dynamically
    const self_exe_dir = std.process.executableDirPathAlloc(init.io, arena) catch ".";

    const sqlite_c_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/lib/sqlite/sqlite3.c" });
    const sqlite_inc_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/lib/sqlite" });
    const runtime_inc_cand1 = try std.fs.path.join(arena, &.{ self_exe_dir, "../src/runtime" });

    var sqlite_c: []const u8 = "src/lib/sqlite/sqlite3.c";
    var sqlite_inc: []const u8 = "-Isrc/lib/sqlite";
    var runtime_inc: []const u8 = "-Isrc/runtime";

    var cand1_exists = false;
    var cand_cwd = std.Io.Dir.cwd();
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

    std.debug.print("Invoking zig cc -O3...\n", .{});
    var child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{ "zig", "cc", out_c_path, sqlite_c, "-o", out_bin_name, "-O3", "-s", sqlite_inc, runtime_inc, "-lws2_32" },
    });
    const term = try child.wait(init.io);

    const duration_s = timer.readSeconds();

    if (term == .exited and term.exited == 0) {
        std.debug.print("\n ⏣ Orbit  build successful\n\n", .{});
        std.debug.print("  Project    {s} v{s}\n", .{config.project, config.version});
        std.debug.print("  Output     {s}\n", .{out_bin_name});
        std.debug.print("  Backend    C -> zig cc -O3\n", .{});
        std.debug.print("  Kynx       {s}\n", .{if (config.no_kynx) "disabled" else "compiled-in"});
        std.debug.print("  Arena      pool={d} cap={d}\n", .{config.arena_pool_size, config.arena_default_capacity});
        std.debug.print("  Duration   {d:.2}s\n\n", .{duration_s});
        return out_bin_name;
    } else {
        std.debug.print("Compilation failed.\n", .{});
        return error.NativeCompilationFailed;
    }
}


fn runBuildMode(init: std.process.Init, file_path: []const u8, debug: bool, no_kynx: bool, config: AtlasConfig) !void {
    _ = debug;
    _ = try compileToBinary(init, file_path, no_kynx, config);
}

fn runExecuteMode(init: std.process.Init, file_path: []const u8, debug: bool, no_kynx: bool, config: AtlasConfig) !void {
    _ = debug;
    const arena = init.arena.allocator();
    const out_bin_name = try compileToBinary(init, file_path, no_kynx, config);

    const bin_path = try std.fmt.allocPrint(arena, ".\\{s}", .{out_bin_name});
    std.debug.print("  [orbit] running {s}\n\n", .{out_bin_name});

    var child = try std.process.spawn(init.io, .{ .argv = &[_][]const u8{bin_path} });
    const term = try child.wait(init.io);

    if (term != .exited or term.exited != 0) {
        const code: i64 = if (term == .exited) @intCast(term.exited) else -1;
        std.debug.print("\n  [orbit] process exited with code {d}\n", .{code});
        return error.OrbitRunFailed;
    }
}

fn runTestMode(init: std.process.Init, file_path: []const u8, debug: bool, no_kynx: bool, config: AtlasConfig) !void {
    _ = debug;
    const arena = init.arena.allocator();
    const out_bin_name = try compileToBinary(init, file_path, no_kynx, config);

    const bin_path = try std.fmt.allocPrint(arena, ".\\{s}", .{out_bin_name});
    std.debug.print("\n  [orbit test] running {s}\n\n", .{out_bin_name});

    var child = try std.process.spawn(init.io, .{ .argv = &[_][]const u8{bin_path} });
    const term = try child.wait(init.io);

    if (term == .exited and term.exited == 0) {
        std.debug.print("\n  \u{2705} [orbit test] PASS ({s})\n", .{file_path});
    } else {
        const code: i64 = if (term == .exited) @intCast(term.exited) else -1;
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
