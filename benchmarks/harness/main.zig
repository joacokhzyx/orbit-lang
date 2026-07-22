/// Orbit benchmark harness.
///
/// Orchestrates compilation, execution, and measurement of compute and HTTP
/// benchmarks across multiple languages. Generates terminal tables, JSON, and
/// Markdown reports.
///
/// Run via:  zig build bench
/// Or:       zig build bench -- --suite compute --lang go,rust
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const exe_ext = if (is_windows) ".exe" else "";
const SEP = std.fs.path.sep_str;

pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;

fn getUnixTimestamp() i64 {
    if (is_windows) {
        var ft: std.os.windows.FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const ft_val = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        return @intCast((ft_val - 116444736000000000) / 10_000_000);
    } else {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
        return ts.sec;
    }
}

// ── ANSI ─────────────────────────────────────────────────────────────────────

const ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const red = "\x1b[31m";
    const magenta = "\x1b[35m";
    const blue = "\x1b[34m";
};

// ── Configuration ─────────────────────────────────────────────────────────────

const Suite = enum { all, compute, http, death };

const Config = struct {
    suite: Suite = .all,
    lang_filter: ?[]const u8 = null, // comma-separated list or null = all
    color: bool = true,
    bench_dir: []const u8 = ".",

    // compute
    compute_runs: u8 = 3,

    // http normal
    http_warmup_n: u32 = 5_000,
    http_requests: u32 = 100_000,
    http_concurrency: u32 = 100,

    // death test
    death_window_s: u8 = 5,
    death_max_s: u32 = 60,
    death_concurrency: u32 = 500,
    death_error_threshold_pct: f64 = 1.0,

    // ports (each language gets base_port + index)
    base_port: u16 = 9100,
};

// ── Language descriptors ───────────────────────────────────────────────────────

const Lang = struct {
    id: []const u8,
    display: []const u8,
    color: []const u8,
    // tool to check availability
    tool: []const u8,
    // how to compile compute bench (null = interpreted)
    compute_compile: ?[]const []const u8,
    // how to run compute bench: args before <test> <N>
    compute_run: []const []const u8,
    // how to compile http server (null = interpreted)
    http_compile: ?[]const []const u8,
    // how to run http server: args before <port>
    http_run: []const []const u8,
};

// Returns a slice of all languages. Caller owns nothing — these are comptime
// string literals.
fn allLangs(a: std.mem.Allocator, bench_dir: []const u8) ![]Lang {
    const bin = try std.fs.path.join(a, &.{ bench_dir, "bin" });
    const compute_dir = try std.fs.path.join(a, &.{ bench_dir, "compute" });
    const http_dir = try std.fs.path.join(a, &.{ bench_dir, "http" });
    const orbit_bin = try std.fs.path.join(a, &.{ bench_dir, "..", "zig-out", "bin", "orbit" ++ exe_ext });

    const langs = try a.alloc(Lang, 8);
    langs[0] = .{
        .id = "orbit-steel",
        .display = "Orbit Steel",
        .color = ansi.cyan,
        .tool = orbit_bin,
        .compute_compile = try a.dupe([]const u8, &.{
            orbit_bin,                                                            "build",
            try std.fs.path.join(a, &.{ compute_dir, "bench.orb" }),              "-o",
            try std.fs.path.join(a, &.{ bin, "compute_orbit_steel" ++ exe_ext }), "--backend=steel",
            "--linker=native",
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_orbit_steel" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            orbit_bin,                                                           "build",
            try std.fs.path.join(a, &.{ http_dir, "server.orb" }),               "-o",
            try std.fs.path.join(a, &.{ bin, "server_orbit_steel" ++ exe_ext }), "--backend=steel",
            "--linker=native",
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "server_orbit_steel" ++ exe_ext }),
        }),
    };
    langs[1] = .{
        .id = "orbit-native",
        .display = "Orbit Native",
        .color = ansi.magenta,
        .tool = orbit_bin,
        .compute_compile = try a.dupe([]const u8, &.{
            orbit_bin,                                                             "build",
            try std.fs.path.join(a, &.{ compute_dir, "bench.orb" }),               "-o",
            try std.fs.path.join(a, &.{ bin, "compute_orbit_native" ++ exe_ext }), "--backend=native",
            "--linker=native",
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_orbit_native" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            orbit_bin,                                                            "build",
            try std.fs.path.join(a, &.{ http_dir, "server.orb" }),                "-o",
            try std.fs.path.join(a, &.{ bin, "server_orbit_native" ++ exe_ext }), "--backend=native",
            "--linker=native",
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "server_orbit_native" ++ exe_ext }),
        }),
    };
    langs[2] = .{
        .id = "go",
        .display = "Go",
        .color = ansi.cyan,
        .tool = "go",
        .compute_compile = try a.dupe([]const u8, &.{
            "go",                                                        "build",                                                "-o",
            try std.fs.path.join(a, &.{ bin, "compute_go" ++ exe_ext }), try std.fs.path.join(a, &.{ compute_dir, "bench.go" }),
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_go" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            "go",                                                       "build",                                              "-o",
            try std.fs.path.join(a, &.{ bin, "server_go" ++ exe_ext }), try std.fs.path.join(a, &.{ http_dir, "server.go" }),
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "server_go" ++ exe_ext }),
        }),
    };
    langs[3] = .{
        .id = "rust",
        .display = "Rust",
        .color = ansi.yellow,
        .tool = "cargo",
        .compute_compile = try a.dupe([]const u8, &.{
            "rustc", "--edition",                                                   "2021",                                                 "-C", "opt-level=3",
            "-o",    try std.fs.path.join(a, &.{ bin, "compute_rust" ++ exe_ext }), try std.fs.path.join(a, &.{ compute_dir, "bench.rs" }),
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_rust" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            "cargo",                                           "build",                                               "--release",
            "--manifest-path",                                 try std.fs.path.join(a, &.{ http_dir, "Cargo.toml" }), "--target-dir",
            try std.fs.path.join(a, &.{ http_dir, "target" }),
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ http_dir, "target", "release", "server_rust" ++ exe_ext }),
        }),
    };
    langs[4] = .{
        .id = "c",
        .display = "C",
        .color = ansi.blue,
        .tool = "zig",
        .compute_compile = try a.dupe([]const u8, &.{
            "zig",                                                      "cc",                                                  "-O2", "-o",
            try std.fs.path.join(a, &.{ bin, "compute_c" ++ exe_ext }), try std.fs.path.join(a, &.{ compute_dir, "bench.c" }),
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_c" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            "zig",                                                     "cc",                                                "-O2", "-o",
            try std.fs.path.join(a, &.{ bin, "server_c" ++ exe_ext }), try std.fs.path.join(a, &.{ http_dir, "server.c" }),
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "server_c" ++ exe_ext }),
        }),
    };
    langs[5] = .{
        .id = "cpp",
        .display = "C++",
        .color = ansi.blue,
        .tool = "zig",
        .compute_compile = try a.dupe([]const u8, &.{
            "zig",                                                        "c++",                                                   "-std=c++17", "-O2", "-o",
            try std.fs.path.join(a, &.{ bin, "compute_cpp" ++ exe_ext }), try std.fs.path.join(a, &.{ compute_dir, "bench.cpp" }),
        }),
        .compute_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "compute_cpp" ++ exe_ext }),
        }),
        .http_compile = try a.dupe([]const u8, &.{
            "zig",                                                       "c++",                                                 "-std=c++17", "-O2", "-o",
            try std.fs.path.join(a, &.{ bin, "server_cpp" ++ exe_ext }), try std.fs.path.join(a, &.{ http_dir, "server.cpp" }),
        }),
        .http_run = try a.dupe([]const u8, &.{
            try std.fs.path.join(a, &.{ bin, "server_cpp" ++ exe_ext }),
        }),
    };
    langs[6] = .{
        .id = "node",
        .display = "Node.js",
        .color = ansi.green,
        .tool = "node",
        .compute_compile = null,
        .compute_run = try a.dupe([]const u8, &.{
            "node", try std.fs.path.join(a, &.{ compute_dir, "bench.js" }),
        }),
        .http_compile = null,
        .http_run = try a.dupe([]const u8, &.{
            "node", try std.fs.path.join(a, &.{ http_dir, "server.js" }),
        }),
    };
    const python_exe = if (is_windows) "python" else "python3";
    langs[7] = .{
        .id = "python",
        .display = "Python",
        .color = ansi.yellow,
        .tool = python_exe,
        .compute_compile = null,
        .compute_run = try a.dupe([]const u8, &.{
            python_exe, try std.fs.path.join(a, &.{ compute_dir, "bench.py" }),
        }),
        .http_compile = null,
        .http_run = try a.dupe([]const u8, &.{
            python_exe, try std.fs.path.join(a, &.{ http_dir, "server.py" }),
        }),
    };
    return langs;
}

// ── Compute tests ─────────────────────────────────────────────────────────────

const ComputeTest = struct {
    name: []const u8,
    param: []const u8,
    description: []const u8,
};

const COMPUTE_TESTS = [_]ComputeTest{
    .{ .name = "fib_recursive", .param = "40", .description = "fib(40) recursive" },
    .{ .name = "fib_iterative", .param = "1000000", .description = "fib(1M) iterative" },
    .{ .name = "sieve", .param = "2000000", .description = "sieve(2M primes)" },
    .{ .name = "sum", .param = "100000000", .description = "sum(1..100M)" },
};

// ── Result types ──────────────────────────────────────────────────────────────

const ComputeResult = struct {
    lang_id: []const u8,
    test_name: []const u8,
    median_ns: u64,
    stddev_ns: u64,
    result_val: []const u8,
    skipped: bool = false,
    skip_reason: []const u8 = "",
};

const HeyResult = struct {
    rps: f64 = 0,
    p50_ms: f64 = 0,
    p95_ms: f64 = 0,
    p99_ms: f64 = 0,
    success_count: u64 = 0,
    error_count: u64 = 0,
    error_rate_pct: f64 = 0,
};

const HttpResult = struct {
    lang_id: []const u8,
    hey: HeyResult,
    skipped: bool = false,
    skip_reason: []const u8 = "",
};

const DeathWindow = struct {
    elapsed_s: f64,
    rps: f64,
    error_rate_pct: f64,
};

const DeathResult = struct {
    lang_id: []const u8,
    peak_rps: f64,
    time_to_death_s: f64, // -1 = survived full duration
    total_requests: u64,
    windows: []DeathWindow,
    skipped: bool = false,
    skip_reason: []const u8 = "",
};

// ── Tool detection ────────────────────────────────────────────────────────────

fn toolExists(alloc: std.mem.Allocator, io: std.Io, tool: []const u8) bool {
    // If it looks like a path (contains sep or starts with .), check file exists
    if (std.mem.indexOfScalar(u8, tool, std.fs.path.sep) != null or
        std.mem.startsWith(u8, tool, "."))
    {
        var cwd = std.Io.Dir.cwd();
        var f = cwd.openFile(io, tool, .{}) catch return false;
        f.close(io);
        return true;
    }
    // Otherwise try to find in PATH via 'which'/'where'
    const which_cmd: []const []const u8 = if (is_windows)
        &.{ "where", tool }
    else
        &.{ "which", tool };
    const r = std.process.run(alloc, io, .{ .argv = which_cmd }) catch return false;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

// ── Compilation ───────────────────────────────────────────────────────────────

fn compile(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    _ = alloc;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return term == .exited and term.exited == 0;
}

fn ensureBinDir(alloc: std.mem.Allocator, io: std.Io, bench_dir: []const u8) !void {
    const bin_path = try std.fs.path.join(alloc, &.{ bench_dir, "bin" });
    defer alloc.free(bin_path);
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, bin_path) catch {};
}

// ── Compute runner ────────────────────────────────────────────────────────────

fn parseComputeOutput(output: []const u8) struct { time_ns: u64, result: []const u8 } {
    var time_ns: u64 = 0;
    var result: []const u8 = "?";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "time_ns: ")) {
            time_ns = std.fmt.parseInt(u64, std.mem.trim(u8, t["time_ns: ".len..], " \t"), 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "result: ")) {
            result = t["result: ".len..];
        }
    }
    return .{ .time_ns = time_ns, .result = result };
}

fn runComputeOnce(
    alloc: std.mem.Allocator,
    io: std.Io,
    run_prefix: []const []const u8,
    test_name: []const u8,
    param: []const u8,
) !struct { time_ns: u64, result: []const u8 } {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.ensureTotalCapacity(alloc, run_prefix.len + 2);
    try argv.appendSlice(alloc, run_prefix);
    try argv.append(alloc, test_name);
    try argv.append(alloc, param);

    const r = try std.process.run(alloc, io, .{ .argv = argv.items });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    const parsed = parseComputeOutput(r.stdout);
    return .{
        .time_ns = parsed.time_ns,
        .result = try alloc.dupe(u8, parsed.result),
    };
}

fn median(values: []u64) u64 {
    if (values.len == 0) return 0;
    std.sort.heap(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn stddev(values: []u64) u64 {
    if (values.len < 2) return 0;
    var sum: u128 = 0;
    for (values) |v| sum += v;
    const mean = sum / values.len;
    var sq_sum: u128 = 0;
    for (values) |v| {
        const diff: i128 = @as(i128, @intCast(v)) - @as(i128, @intCast(mean));
        sq_sum += @as(u128, @intCast(diff * diff));
    }
    return @intCast(std.math.sqrt(sq_sum / values.len));
}

// ── Server management ─────────────────────────────────────────────────────────

fn waitForServerReady(io: std.Io, port: u16, timeout_ms: u64) !void {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    const start_time = try std.time.Instant.now();
    const timeout_ns = timeout_ms * std.time.ns_per_ms;
    while (true) {
        const stream = addr.connect(io, .{ .mode = .stream }) catch {
            const current_time = try std.time.Instant.now();
            if (current_time.since(start_time) >= timeout_ns) {
                return error.ServerTimeout;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        stream.close(io);
        return;
    }
}

// ── hey invocation & parsing ──────────────────────────────────────────────────

fn runHey(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    n: u32,
    c: u32,
) !HeyResult {
    const n_str = try std.fmt.allocPrint(alloc, "{d}", .{n});
    defer alloc.free(n_str);
    const c_str = try std.fmt.allocPrint(alloc, "{d}", .{c});
    defer alloc.free(c_str);

    const argv = [_][]const u8{ "hey", "-n", n_str, "-c", c_str, url };
    const r = try std.process.run(alloc, io, .{ .argv = &argv });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    return parseHeyOutput(r.stdout);
}

fn runHeyDuration(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    duration_s: u8,
    c: u32,
) !HeyResult {
    const dur_str = try std.fmt.allocPrint(alloc, "{d}s", .{duration_s});
    defer alloc.free(dur_str);
    const c_str = try std.fmt.allocPrint(alloc, "{d}", .{c});
    defer alloc.free(c_str);

    const argv = [_][]const u8{ "hey", "-z", dur_str, "-c", c_str, url };
    const r = try std.process.run(alloc, io, .{ .argv = &argv });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    return parseHeyOutput(r.stdout);
}

fn parseHeyOutput(output: []const u8) HeyResult {
    var r: HeyResult = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (std.mem.startsWith(u8, line, "Requests/sec:")) {
            const val = std.mem.trim(u8, line["Requests/sec:".len..], " \t");
            r.rps = std.fmt.parseFloat(f64, val) catch 0;
        } else if (std.mem.startsWith(u8, line, "50%")) {
            r.p50_ms = parseLatencyLine(line);
        } else if (std.mem.startsWith(u8, line, "95%")) {
            r.p95_ms = parseLatencyLine(line);
        } else if (std.mem.startsWith(u8, line, "99%")) {
            r.p99_ms = parseLatencyLine(line);
        } else if (std.mem.startsWith(u8, line, "[")) {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const code_str = line[1..end];
            const count_part = std.mem.trim(u8, line[end + 1 ..], " \t");
            const space = std.mem.indexOfScalar(u8, count_part, ' ') orelse count_part.len;
            const count = std.fmt.parseInt(u64, count_part[0..space], 10) catch continue;
            const code = std.fmt.parseInt(u16, code_str, 10) catch continue;
            if (code == 200) {
                r.success_count += count;
            } else {
                r.error_count += count;
            }
        }
    }
    const total = r.success_count + r.error_count;
    if (total > 0) {
        r.error_rate_pct = @as(f64, @floatFromInt(r.error_count)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
    return r;
}

fn parseLatencyLine(line: []const u8) f64 {
    // "50% in 0.0049 secs"
    const in_idx = std.mem.indexOf(u8, line, " in ") orelse return 0;
    const after = line[in_idx + 4 ..];
    const space = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const secs = std.fmt.parseFloat(f64, after[0..space]) catch return 0;
    return secs * 1000.0; // convert to milliseconds
}

// ── Reporting ─────────────────────────────────────────────────────────────────

const Writer = std.Io.Writer;

fn printHeader(w: anytype, text: []const u8, cfg: Config) !void {
    if (cfg.color) {
        try w.print("\n{s}{s}── {s} ──{s}\n", .{ ansi.bold, ansi.cyan, text, ansi.reset });
    } else {
        try w.print("\n── {s} ──\n", .{text});
    }
}

fn fmtNs(ns: u64) [16]u8 {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    if (ns < 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d} ns", .{ns}) catch {};
    } else if (ns < 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2} µs", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch {};
    } else if (ns < 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.3} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:.4} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch {};
    }
    return buf;
}

fn printComputeTable(
    w: anytype,
    results: []ComputeResult,
    cfg: Config,
    alloc: std.mem.Allocator,
) !void {
    _ = alloc;
    try printHeader(w, "Compute Benchmarks", cfg);
    try w.print("{s:<20} {s:<22} {s:>14} {s:>14}{s}\n", .{
        "Language", "Test", "Median", "Stddev", "",
    });
    try w.writeAll(("─" ** 72) ++ "\n");
    for (results) |r| {
        if (r.skipped) {
            if (cfg.color) {
                try w.print("{s}{s:<20}{s} {s:<22} {s}skipped: {s}{s}\n", .{
                    ansi.dim,    r.lang_id, ansi.reset,
                    r.test_name, ansi.dim,  r.skip_reason,
                    ansi.reset,
                });
            } else {
                try w.print("{s:<20} {s:<22} skipped: {s}\n", .{ r.lang_id, r.test_name, r.skip_reason });
            }
        } else {
            const med = fmtNs(r.median_ns);
            const std_ = fmtNs(r.stddev_ns);
            try w.print("{s:<20} {s:<22} {s:>14} {s:>14}\n", .{
                r.lang_id,                       r.test_name,
                std.mem.trim(u8, &med, "\x00 "), std.mem.trim(u8, &std_, "\x00 "),
            });
        }
    }
}

fn printHttpTable(w: anytype, results: []HttpResult, cfg: Config) !void {
    try printHeader(w, "HTTP Throughput  (hey -n 100000 -c 100)", cfg);
    try w.print("{s:<20} {s:>12} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{
        "Language", "RPS", "p50 ms", "p95 ms", "p99 ms", "Errors",
    });
    try w.writeAll(("─" ** 72) ++ "\n");
    for (results) |r| {
        if (r.skipped) {
            if (cfg.color) {
                try w.print("{s}{s:<20}{s}   {s}skipped: {s}{s}\n", .{
                    ansi.dim, r.lang_id,     ansi.reset,
                    ansi.dim, r.skip_reason, ansi.reset,
                });
            } else {
                try w.print("{s:<20}   skipped: {s}\n", .{ r.lang_id, r.skip_reason });
            }
        } else {
            const h = r.hey;
            try w.print("{s:<20} {d:>12.0} {d:>10.2} {d:>10.2} {d:>10.2} {d:>7.2}%\n", .{
                r.lang_id, h.rps, h.p50_ms, h.p95_ms, h.p99_ms, h.error_rate_pct,
            });
        }
    }
}

fn printDeathTable(w: anytype, results: []DeathResult, cfg: Config) !void {
    try printHeader(w, "Death / Stress Test  (hey -z 5s -c 500, max 60s)", cfg);
    try w.print("{s:<20} {s:>12} {s:>14} {s:>14}\n", .{
        "Language", "Peak RPS", "Time-to-death", "Requests total",
    });
    try w.writeAll(("─" ** 62) ++ "\n");
    for (results) |r| {
        if (r.skipped) {
            if (cfg.color) {
                try w.print("{s}{s:<20}{s}   {s}skipped: {s}{s}\n", .{
                    ansi.dim, r.lang_id,     ansi.reset,
                    ansi.dim, r.skip_reason, ansi.reset,
                });
            } else {
                try w.print("{s:<20}   skipped: {s}\n", .{ r.lang_id, r.skip_reason });
            }
        } else {
            const death = if (r.time_to_death_s < 0)
                "survived"
            else blk: {
                break :blk "error";
            };
            _ = death;
            if (r.time_to_death_s < 0) {
                try w.print("{s:<20} {d:>12.0} {s:>14} {d:>14}\n", .{
                    r.lang_id, r.peak_rps, "survived", r.total_requests,
                });
            } else {
                try w.print("{s:<20} {d:>12.0} {d:>12.1}s {d:>14}\n", .{
                    r.lang_id, r.peak_rps, r.time_to_death_s, r.total_requests,
                });
            }
        }
    }
}

// ── JSON report ───────────────────────────────────────────────────────────────

fn writeJsonReport(
    alloc: std.mem.Allocator,
    io: std.Io,
    bench_dir: []const u8,
    compute: []ComputeResult,
    http: []HttpResult,
    death: []DeathResult,
    sysinfo: SysInfo,
) !void {
    const results_dir = try std.fs.path.join(alloc, &.{ bench_dir, "results" });
    std.Io.Dir.cwd().createDirPath(io, results_dir) catch {};

    const epoch = getUnixTimestamp();
    const filename = try std.fmt.allocPrint(alloc, "{s}{s}{d}.json", .{ results_dir, SEP, epoch });
    defer alloc.free(filename);

    var cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, filename, .{ .truncate = true });
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &file_buf);
    const w = &file_writer.interface;

    try w.writeAll("{\n");
    try w.print("  \"generated_at\": {d},\n", .{epoch});
    try w.print("  \"system\": {{ \"os\": \"{s}\", \"cpu_count\": {d} }},\n", .{
        sysinfo.os, sysinfo.cpu_count,
    });

    // compute
    try w.writeAll("  \"compute\": [\n");
    for (compute, 0..) |r, i| {
        const comma = if (i < compute.len - 1) "," else "";
        if (r.skipped) {
            try w.print("    {{\"lang\": \"{s}\", \"test\": \"{s}\", \"skipped\": true}}{s}\n", .{
                r.lang_id, r.test_name, comma,
            });
        } else {
            try w.print("    {{\"lang\": \"{s}\", \"test\": \"{s}\", \"median_ns\": {d}, \"stddev_ns\": {d}}}{s}\n", .{
                r.lang_id, r.test_name, r.median_ns, r.stddev_ns, comma,
            });
        }
    }
    try w.writeAll("  ],\n");

    // http
    try w.writeAll("  \"http\": [\n");
    for (http, 0..) |r, i| {
        const comma = if (i < http.len - 1) "," else "";
        if (r.skipped) {
            try w.print("    {{\"lang\": \"{s}\", \"skipped\": true}}{s}\n", .{ r.lang_id, comma });
        } else {
            try w.print("    {{\"lang\": \"{s}\", \"rps\": {d:.1}, \"p50_ms\": {d:.3}, \"p95_ms\": {d:.3}, \"p99_ms\": {d:.3}, \"error_rate_pct\": {d:.4}}}{s}\n", .{
                r.lang_id, r.hey.rps, r.hey.p50_ms, r.hey.p95_ms, r.hey.p99_ms, r.hey.error_rate_pct, comma,
            });
        }
    }
    try w.writeAll("  ],\n");

    // death
    try w.writeAll("  \"death\": [\n");
    for (death, 0..) |r, i| {
        const comma = if (i < death.len - 1) "," else "";
        if (r.skipped) {
            try w.print("    {{\"lang\": \"{s}\", \"skipped\": true}}{s}\n", .{ r.lang_id, comma });
        } else {
            try w.print("    {{\"lang\": \"{s}\", \"peak_rps\": {d:.1}, \"time_to_death_s\": {d:.1}, \"total_requests\": {d}}}{s}\n", .{
                r.lang_id, r.peak_rps, r.time_to_death_s, r.total_requests, comma,
            });
        }
    }
    try w.writeAll("  ]\n}\n");

    try file_writer.flush();
    std.debug.print("  JSON report: {s}\n", .{filename});
}

// ── System info ───────────────────────────────────────────────────────────────

const SysInfo = struct {
    os: []const u8,
    cpu_count: usize,
};

fn getSysInfo(alloc: std.mem.Allocator) !SysInfo {
    _ = alloc;
    return .{
        .os = @tagName(builtin.os.tag),
        .cpu_count = std.Thread.getCpuCount() catch 1,
    };
}

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    var stdout_writer = std.Io.File.Writer.init(stdout_file, init.io, &.{});
    var stderr_writer = std.Io.File.Writer.init(stderr_file, init.io, &.{});
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Parse args
    var cfg = Config{};
    const args = try init.minimal.args.toSlice(alloc);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--suite") and i + 1 < args.len) {
            i += 1;
            cfg.suite = std.meta.stringToEnum(Suite, args[i]) orelse .all;
        } else if (std.mem.eql(u8, arg, "--lang") and i + 1 < args.len) {
            i += 1;
            cfg.lang_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            cfg.color = false;
        } else if (std.mem.eql(u8, arg, "--bench-dir") and i + 1 < args.len) {
            i += 1;
            cfg.bench_dir = args[i];
        }
    }

    const sysinfo = try getSysInfo(alloc);
    const langs = try allLangs(alloc, cfg.bench_dir);

    if (cfg.color) {
        try stdout.print("{s}{s}Orbit Benchmark Suite{s}\n", .{ ansi.bold, ansi.cyan, ansi.reset });
    } else {
        try stdout.writeAll("Orbit Benchmark Suite\n");
    }
    try stdout.print("OS: {s}  CPUs: {d}\n", .{ sysinfo.os, sysinfo.cpu_count });

    // Create bin/ dir
    try ensureBinDir(alloc, init.io, cfg.bench_dir);

    // Detect + compile
    var available = try alloc.alloc(bool, langs.len);
    defer alloc.free(available);

    try stdout.writeAll("\nDetecting tools and compiling...\n");
    for (langs, 0..) |lang, li| {
        const found = toolExists(alloc, init.io, lang.tool);
        available[li] = found;
        if (!found) {
            try stderr.print("  skip  {s:<18}  (tool not found: {s})\n", .{ lang.id, lang.tool });
            continue;
        }
        try stdout.print("  found {s}\n", .{lang.id});

        // compile compute bench
        if (cfg.suite == .all or cfg.suite == .compute) {
            if (lang.compute_compile) |cc| {
                const ok = compile(alloc, init.io, cc) catch false;
                if (!ok) {
                    try stderr.print("  WARN  {s:<18}  compute compile failed\n", .{lang.id});
                    available[li] = false;
                }
            }
        }
        // compile http server
        if (cfg.suite == .all or cfg.suite == .http or cfg.suite == .death) {
            if (lang.http_compile) |hc| {
                const ok = compile(alloc, init.io, hc) catch false;
                if (!ok) {
                    try stderr.print("  WARN  {s:<18}  http compile failed\n", .{lang.id});
                    available[li] = false;
                }
            }
        }
    }

    // ── Compute suite ─────────────────────────────────────────────────────────
    var compute_results = std.ArrayList(ComputeResult).empty;
    defer compute_results.deinit(alloc);

    if (cfg.suite == .all or cfg.suite == .compute) {
        try printHeader(stdout, "Running compute benchmarks...", cfg);

        for (langs, 0..) |lang, li| {
            if (!available[li]) continue;
            if (!langInFilter(lang.id, cfg.lang_filter)) continue;

            for (COMPUTE_TESTS) |t| {
                if ((std.mem.eql(u8, lang.id, "orbit-steel") or std.mem.eql(u8, lang.id, "orbit-native")) and std.mem.eql(u8, t.name, "sieve")) {
                    try stdout.print("  {s:<18}  {s}...  SKIP (not implemented)\n", .{ lang.id, t.description });
                    try compute_results.append(alloc, .{
                        .lang_id = lang.id,
                        .test_name = t.name,
                        .median_ns = 0,
                        .stddev_ns = 0,
                        .result_val = "?",
                        .skipped = true,
                        .skip_reason = "sieve not implemented in Orbit language",
                    });
                    continue;
                }

                try stdout.print("  {s:<18}  {s}...", .{ lang.id, t.description });

                var times: [8]u64 = undefined;
                var run_count: u8 = 0;
                var last_result: []const u8 = "?";

                for (0..cfg.compute_runs) |_| {
                    const r = runComputeOnce(alloc, init.io, lang.compute_run, t.name, t.param) catch {
                        break;
                    };
                    times[run_count] = r.time_ns;
                    last_result = r.result;
                    run_count += 1;
                    if (r.time_ns > 2_000_000_000) break; // Don't repeat multi-second runs
                }

                if (run_count == 0) {
                    try stdout.writeAll("  FAIL\n");
                    try compute_results.append(alloc, .{
                        .lang_id = lang.id,
                        .test_name = t.name,
                        .median_ns = 0,
                        .stddev_ns = 0,
                        .result_val = "?",
                        .skipped = true,
                        .skip_reason = "run failed",
                    });
                } else {
                    const med = median(times[0..run_count]);
                    const sd = stddev(times[0..run_count]);
                    const med_fmt = fmtNs(med);
                    try stdout.print("  {s}\n", .{std.mem.trim(u8, &med_fmt, "\x00 ")});
                    try compute_results.append(alloc, .{
                        .lang_id = lang.id,
                        .test_name = t.name,
                        .median_ns = med,
                        .stddev_ns = sd,
                        .result_val = last_result,
                        .skipped = false,
                    });
                }
            }
        }
    }

    // ── HTTP suite ────────────────────────────────────────────────────────────
    var http_results = std.ArrayList(HttpResult).empty;
    defer http_results.deinit(alloc);

    if (cfg.suite == .all or cfg.suite == .http) {
        try printHeader(stdout, "Running HTTP benchmarks...", cfg);

        const hey_ok = toolExists(alloc, init.io, "hey");
        if (!hey_ok) {
            try stderr.writeAll("  'hey' not found — skipping HTTP suite\n");
            try stderr.writeAll("  Install: go install github.com/rakyll/hey@latest\n");
        } else {
            var port: u16 = cfg.base_port;
            for (langs, 0..) |lang, li| {
                if (!available[li]) continue;
                if (!langInFilter(lang.id, cfg.lang_filter)) continue;

                defer port += 1;
                const url_normal = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{port});
                defer alloc.free(url_normal);

                try stdout.print("  {s:<18}  starting server on :{d}...", .{ lang.id, port });

                // Build server argv
                var srv_argv = std.ArrayList([]const u8).empty;
                defer srv_argv.deinit(alloc);
                try srv_argv.ensureTotalCapacity(alloc, lang.http_run.len + 1);
                try srv_argv.appendSlice(alloc, lang.http_run);
                const port_str = try std.fmt.allocPrint(alloc, "{d}", .{port});
                defer alloc.free(port_str);
                try srv_argv.append(alloc, port_str);

                var server = std.process.spawn(init.io, .{
                    .argv = srv_argv.items,
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch {
                    try stdout.writeAll("  FAIL (spawn)\n");
                    try http_results.append(alloc, .{
                        .lang_id = lang.id,
                        .hey = .{},
                        .skipped = true,
                        .skip_reason = "spawn failed",
                    });
                    continue;
                };

                waitForServerReady(init.io, port, 10_000) catch {
                    server.kill(init.io);
                    try stdout.writeAll("  FAIL (timeout)\n");
                    try http_results.append(alloc, .{
                        .lang_id = lang.id,
                        .hey = .{},
                        .skipped = true,
                        .skip_reason = "server did not bind within 10s",
                    });
                    continue;
                };

                try stdout.writeAll("  ready\n");

                // Warm-up
                try stdout.print("  {s:<18}  warming up ({d} reqs)...", .{ lang.id, cfg.http_warmup_n });
                _ = runHey(alloc, init.io, url_normal, cfg.http_warmup_n, 50) catch {};
                try stdout.writeAll("  done\n");

                // Benchmark
                try stdout.print("  {s:<18}  benchmarking ({d} reqs, c={d})...", .{
                    lang.id, cfg.http_requests, cfg.http_concurrency,
                });
                const hey_res = runHey(alloc, init.io, url_normal, cfg.http_requests, cfg.http_concurrency) catch HeyResult{};
                try stdout.print("  {d:.0} RPS\n", .{hey_res.rps});

                try http_results.append(alloc, .{
                    .lang_id = lang.id,
                    .hey = hey_res,
                });

                // Shutdown
                server.kill(init.io);
                std.Io.sleep(init.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
            }
        }
    }

    // ── Death suite ───────────────────────────────────────────────────────────
    var death_results = std.ArrayList(DeathResult).empty;
    defer death_results.deinit(alloc);

    if (cfg.suite == .all or cfg.suite == .death) {
        try printHeader(stdout, "Running death / stress tests...", cfg);

        const hey_ok = toolExists(alloc, init.io, "hey");
        if (!hey_ok) {
            try stderr.writeAll("  'hey' not found — skipping death suite\n");
        } else {
            var port: u16 = cfg.base_port + 50;
            for (langs, 0..) |lang, li| {
                if (!available[li]) continue;
                if (!langInFilter(lang.id, cfg.lang_filter)) continue;

                defer port += 1;
                const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{port});
                defer alloc.free(url);

                try stdout.print("  {s:<18}  starting...", .{lang.id});

                var srv_argv = std.ArrayList([]const u8).empty;
                defer srv_argv.deinit(alloc);
                try srv_argv.ensureTotalCapacity(alloc, lang.http_run.len + 1);
                try srv_argv.appendSlice(alloc, lang.http_run);
                const port_str = try std.fmt.allocPrint(alloc, "{d}", .{port});
                defer alloc.free(port_str);
                try srv_argv.append(alloc, port_str);

                var server = std.process.spawn(init.io, .{
                    .argv = srv_argv.items,
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch {
                    try stdout.writeAll("  FAIL (spawn)\n");
                    try death_results.append(alloc, .{
                        .lang_id = lang.id,
                        .peak_rps = 0,
                        .time_to_death_s = 0,
                        .total_requests = 0,
                        .windows = &.{},
                        .skipped = true,
                        .skip_reason = "spawn failed",
                    });
                    continue;
                };

                waitForServerReady(init.io, port, 10_000) catch {
                    server.kill(init.io);
                    try stdout.writeAll("  FAIL (timeout)\n");
                    try death_results.append(alloc, .{
                        .lang_id = lang.id,
                        .peak_rps = 0,
                        .time_to_death_s = 0,
                        .total_requests = 0,
                        .windows = &.{},
                        .skipped = true,
                        .skip_reason = "server did not bind",
                    });
                    continue;
                };

                try stdout.writeAll("  ready  running stress...\n");

                var windows = std.ArrayList(DeathWindow).empty;
                defer windows.deinit(alloc);

                var elapsed: f64 = 0;
                var peak_rps: f64 = 0;
                var total_requests: u64 = 0;
                var time_to_death: f64 = -1;
                var consecutive_errors: u8 = 0;

                while (elapsed < @as(f64, @floatFromInt(cfg.death_max_s))) {
                    const window = runHeyDuration(alloc, init.io, url, cfg.death_window_s, cfg.death_concurrency) catch break;
                    elapsed += @as(f64, @floatFromInt(cfg.death_window_s));
                    total_requests += window.success_count + window.error_count;
                    if (window.rps > peak_rps) peak_rps = window.rps;

                    try windows.append(alloc, .{
                        .elapsed_s = elapsed,
                        .rps = window.rps,
                        .error_rate_pct = window.error_rate_pct,
                    });

                    try stdout.print("    {d:>5.0}s  {d:>9.0} RPS  {d:.2}% errors\n", .{
                        elapsed, window.rps, window.error_rate_pct,
                    });

                    if (window.error_rate_pct >= cfg.death_error_threshold_pct) {
                        consecutive_errors += 1;
                        if (consecutive_errors >= 2) {
                            time_to_death = elapsed;
                            break;
                        }
                    } else {
                        consecutive_errors = 0;
                    }
                }

                server.kill(init.io);

                if (time_to_death < 0) {
                    try stdout.print("  {s:<18}  survived {d:.0}s  peak {d:.0} RPS\n", .{
                        lang.id, elapsed, peak_rps,
                    });
                } else {
                    try stdout.print("  {s:<18}  died at {d:.0}s  peak {d:.0} RPS\n", .{
                        lang.id, time_to_death, peak_rps,
                    });
                }

                try death_results.append(alloc, .{
                    .lang_id = lang.id,
                    .peak_rps = peak_rps,
                    .time_to_death_s = time_to_death,
                    .total_requests = total_requests,
                    .windows = try windows.toOwnedSlice(alloc),
                });

                std.Io.sleep(init.io, std.Io.Duration.fromSeconds(3), .awake) catch {};
            }
        }
    }

    // ── Final tables ──────────────────────────────────────────────────────────
    if (compute_results.items.len > 0) {
        try printComputeTable(stdout, compute_results.items, cfg, alloc);
    }
    if (http_results.items.len > 0) {
        try printHttpTable(stdout, http_results.items, cfg);
    }
    if (death_results.items.len > 0) {
        try printDeathTable(stdout, death_results.items, cfg);
    }

    // ── JSON report ───────────────────────────────────────────────────────────
    try writeJsonReport(
        alloc,
        init.io,
        cfg.bench_dir,
        compute_results.items,
        http_results.items,
        death_results.items,
        sysinfo,
    );

    try stdout.writeAll("\nDone.\n");
}

fn langInFilter(id: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    var it = std.mem.splitScalar(u8, f, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, std.mem.trim(u8, tok, " "), id)) return true;
    }
    return false;
}
