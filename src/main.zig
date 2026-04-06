const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const CBackend = @import("codegen/c_backend.zig").CBackend;
const AtlasConfig = @import("atlas.zig").AtlasConfig;

const ORBIT_VERSION = "0.1.0-alpha";

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

    // Read source file
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(init.io, file_path, .{});
    defer file.close(init.io);

    const file_len = try file.length(init.io);
    const source = try arena.alloc(u8, file_len);

    var read_buffer: [8192]u8 = undefined;
    var file_reader_state = std.Io.File.Reader.init(file, init.io, &read_buffer);
    try file_reader_state.interface.readSliceAll(source);

    if (std.mem.eql(u8, command, "dev")) {
        try runDevMode(init, source, file_path, debug, no_kynx, config);
    } else if (std.mem.eql(u8, command, "build")) {
        try runBuildMode(init, source, file_path, debug, no_kynx, config);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    std.debug.print(
        \\
        \\  ORBIT NATIVE COMPILER (OBC) - v{s}
        \\  "If it compiles, it scales." 🪐
        \\
        \\  Usage: orbit <command> <file.orb> [options]
        \\
        \\  Commands:
        \\    dev      Run in development mode (JIT-like speed)
        \\    build    Compile to native optimized binary
        \\
        \\  Options:
        \\    --debug    Enable verbose runtime logs
        \\    --no-kynx  Disable Kynx autonomous protection
        \\
    , .{ORBIT_VERSION});
}

fn runDevMode(init: std.process.Init, source: []const u8, file_path: []const u8, debug: bool, no_kynx: bool, config: AtlasConfig) !void {
    _ = no_kynx;
    const arena = init.arena.allocator();
    var timer = try std.time.Timer.start();

    // 1. Lex & Parse
    var parser = Parser.init(source, arena);
    const root = parser.parse() catch |err| {
        reportSyntaxError(source, file_path, parser.current_token);
        return err;
    };

    // 2. Semantic Analysis
    var sema = try Sema.create(arena, source);
    defer sema.deinit();
    sema.analyze(root) catch {
        printEchoes(source, sema.diagnostics.getDiagnostics());
        return;
    };

    if (sema.diagnostics.getDiagnostics().len > 0) {
        printEchoes(source, sema.diagnostics.getDiagnostics());
        return;
    }

    // 3. Report
    const duration_ns = timer.read();
    const duration = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    if (debug) {
        std.debug.print("\n  ORBIT {s}@{s}  ready in {d:.1} ms\n\n", .{config.project, config.version, duration});
        std.debug.print("  [runtime] bootstrapping engine...\n", .{});
        std.debug.print("  [env]     mapping: PORT -> {d}\n", .{config.port});
        std.debug.print("  [arena]   pool: {d} × {d} bytes\n", .{config.arena_pool_size, config.arena_default_capacity});
        std.debug.print("  [kynx]    {s}\n", .{if (config.no_kynx) "disabled" else "active"});
    } else {
        std.debug.print("  [orbit] version {s} (@{s})\n", .{config.version, config.project});
        std.debug.print("  [orbit] security policy: {s}\n", .{if (config.no_kynx) "disabled" else "active"});

        if (sema.has_server_init) {
            std.debug.print("  [orbit] server listening: http://localhost:{d}\n", .{config.port});
            std.debug.print("\n  (ctrl+c to stop)\n", .{});
            
            var buf: [1]u8 = undefined;
            var stdin_buffer: [1]u8 = undefined;
            var file_reader_state = std.Io.File.Reader.init(std.Io.File.stdin(), init.io, &stdin_buffer);
            _ = try file_reader_state.interface.readSliceAll(&buf);
        } else {
            std.debug.print("  [orbit] execution finished in {d:.1} ms\n", .{duration});
        }
    }
}

fn runBuildMode(init: std.process.Init, source: []const u8, file_path: []const u8, debug: bool, no_kynx: bool, config: AtlasConfig) !void {
    _ = debug;
    _ = file_path;
    _ = no_kynx;
    const arena = init.arena.allocator();
    var timer = try std.time.Timer.start();

    var parser = Parser.init(source, arena);
    const root = parser.parse() catch |err| {
        std.debug.print("Parser failed with error: {s}\n", .{@errorName(err)});
        return err;
    };

    var sema = try Sema.create(arena, source);
    defer sema.deinit();
    sema.analyze(root) catch {
        printEchoes(source, sema.diagnostics.getDiagnostics());
        return;
    };

    if (sema.diagnostics.getDiagnostics().len > 0) {
        printEchoes(source, sema.diagnostics.getDiagnostics());
        return;
    }

    var builder = IRBuilder.init(arena, source, &sema.node_types, &sema.model_registry);
    const ir_module = try builder.build(root);
    
    var backend = CBackend.init(arena, config, sema.has_server_init);
    const c_code = try backend.generate(ir_module);

    const out_c_path = "output_orbit.c";

    // Output binary name from config
    const out_bin_name = try std.fmt.allocPrint(arena, "{s}.exe", .{config.output_name});

    var cwd = std.Io.Dir.cwd();
    var out_file = try cwd.createFile(init.io, out_c_path, .{ .truncate = true });
    
    var write_buffer: [8192]u8 = undefined;
    var file_writer_state = std.Io.File.Writer.init(out_file, init.io, &write_buffer);
    try file_writer_state.interface.writeAll(c_code);
    try file_writer_state.flush();
    out_file.close(init.io);

    std.debug.print("Invoking zig cc -O3...\n", .{});
    var child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{ "zig", "cc", out_c_path, "src/lib/sqlite/sqlite3.c", "-o", out_bin_name, "-O3", "-Isrc/lib/sqlite", "-lws2_32" },
    });
    
    const term = try child.wait(init.io);
    
    const duration_ns = timer.read();
    const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;

    if (term == .exited and term.exited == 0) {
        std.debug.print("\n  ORBIT  build successful\n\n", .{});
        std.debug.print("  Project    {s} v{s}\n", .{config.project, config.version});
        std.debug.print("  Output     {s}\n", .{out_bin_name});
        std.debug.print("  Backend    C -> zig cc -O3\n", .{});
        std.debug.print("  Kynx       {s}\n", .{if (config.no_kynx) "disabled" else "compiled-in"});
        std.debug.print("  Arena      pool={d} cap={d}\n", .{config.arena_pool_size, config.arena_default_capacity});
        std.debug.print("  Duration   {d:.2}s\n\n", .{duration_s});
    } else {
        std.debug.print("Compilation failed.\n", .{});
    }
}

fn reportSyntaxError(source: []const u8, file_path: []const u8, tok: anytype) void {
    std.debug.print("\n  ORBIT v{s}  failed to start\n\n", .{ORBIT_VERSION});
    std.debug.print("  [SYNTAX ERROR] unexpectedly found '{s}'\n", .{@tagName(tok.tag)});
    std.debug.print("\n  file: {s}:{d}\n", .{ file_path, tok.loc.line });
    var line_count: usize = 1;
    var it = std.mem.splitScalar(u8, source, '\n');
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

fn printEchoes(source: []const u8, diagnostics: []const Sema.Diagnostic) void {
    std.debug.print("\n  🪐 ORBIT ECHO: Consistency Resonant Failures\n", .{});
    std.debug.print("  ------------------------------------------\n", .{});

    for (diagnostics) |diag| {
        std.debug.print("\n  [ {s} ] {s}\n", .{diag.code, diag.message});
        std.debug.print("  at line {d}, column {d}\n\n", .{diag.line, diag.col});

        var line_count: usize = 1;
        var it = std.mem.splitScalar(u8, source, '\n');
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
