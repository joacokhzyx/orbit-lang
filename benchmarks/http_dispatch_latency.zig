/// HTTP dispatch latency micro-benchmark for the Orbit C runtime.
///
/// Measures the per-request cost of the network-free parse/dispatch path in
/// `src/runtime/http.c` (`orbit_http_parse_request`) over a fixed set of
/// realistic in-memory HTTP/1.1 request buffers.  No sockets, no I/O.
///
/// A fixed array of request templates is dispatched repeatedly through the
/// runtime's parse API; each request is copied into a fresh scratch buffer
/// (mirroring a freshly-received packet, since the parser NUL-terminates the
/// buffer in place), parsed into an `OrbitRequest`, and the request target is
/// folded into a checksum so the optimizer cannot elide the work.  The arena
/// is reset after every request to model per-request arena reuse.
///
/// Results are reported as the median over N measured runs of M requests:
/// requests/sec, average latency per request, and p50/p95/p99 latencies in ns
/// computed over per-request RDTSC samples (the same clock the runtime itself
/// uses in `src/runtime/performance.h`), calibrated to nanoseconds.
///
/// Run via:  zig build bench-http-dispatch
/// Or:       zig build bench-http-dispatch -- --requests=200000 --runs=20
const std = @import("std");

const REQUEST_TEMPLATES = [_][]const u8{
    "GET /users/42 HTTP/1.1\r\nHost: localhost\r\nUser-Agent: orbit-bench/1.0\r\nAccept: */*\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n",
    "POST /users HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"name\":\"Ada\",\"age\":36}",
    "GET /search?q=orbit&page=2 HTTP/1.1\r\nHost: localhost\r\n\r\n",
    "PUT /users/42 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12\r\n\r\n{\"age\":37}",
    "DELETE /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n",
    "GET /_pulse HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\n\r\n",
    "POST /auth/login HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 16\r\n\r\nuser=ada&pass=x",
};

const SCRATCH_SIZE = 512;
const FNV1A_OFFSET: u64 = 0xcbf29ce484222325;
const FNV1A_PRIME: u64 = 0x100000001b3;

const OrbitArena = opaque {};

/// Mirrors the `OrbitRequest` struct from `src/runtime/http.c`.
const OrbitRequest = extern struct {
    method: ?[*]u8,
    path: ?[*]u8,
    query: ?[*]u8,
    body: ?[*]u8,
    headers: ?[*]u8,
    body_len: usize,
    headers_len: usize,
};

extern fn orbit_arena_create(initial_capacity: usize) ?*OrbitArena;
extern fn orbit_arena_destroy(arena: *OrbitArena) void;
extern fn orbit_arena_reset(arena: *OrbitArena) void;
extern fn orbit_http_parse_request(arena: *OrbitArena, raw: [*]const u8, raw_len: usize, out_req: *?*OrbitRequest) usize;

const Config = struct {
    requests_per_run: u64 = 200_000,
    runs: u32 = 20,
    warmup: u64 = 10_000,
};

fn parseArgs(args: []const []const u8) !Config {
    var cfg = Config{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--requests=")) {
            cfg.requests_per_run = std.fmt.parseInt(u64, arg["--requests=".len..], 10) catch {
                std.log.err("invalid --requests value: {s}", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            cfg.runs = std.fmt.parseInt(u32, arg["--runs=".len..], 10) catch {
                std.log.err("invalid --runs value: {s}", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.startsWith(u8, arg, "--warmup=")) {
            cfg.warmup = std.fmt.parseInt(u64, arg["--warmup=".len..], 10) catch {
                std.log.err("invalid --warmup value: {s}", .{arg});
                return error.InvalidArgs;
            };
        }
    }
    if (cfg.runs == 0 or cfg.requests_per_run == 0) return error.InvalidArgs;
    return cfg;
}

/// Reads the x86-64 timestamp counter, the same clock the runtime's
/// `orbit_rdtsc()` in `src/runtime/performance.h` is built on.
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// Busy-waits ~60 ms while counting TSC cycles against the boot clock, then
/// returns cycles-per-nanosecond so RDTSC samples can be converted to ns.
fn calibrateCyclesPerNs(io: std.Io) f64 {
    const start_ts = std.Io.Clock.Timestamp.now(io, .boot);
    const start_c = rdtsc();
    var target: i96 = 0;
    while (target < 60_000_000) {
        const now = std.Io.Clock.Timestamp.now(io, .boot);
        target = start_ts.durationTo(now).raw.nanoseconds;
    }
    const end_c = rdtsc();
    const end_ts = std.Io.Clock.Timestamp.now(io, .boot);
    const cycles: u64 = end_c - start_c;
    const ns: u64 = @intCast(start_ts.durationTo(end_ts).raw.nanoseconds);
    return @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(ns));
}

/// Dispatches one HTTP request: copies the template into a fresh scratch
/// buffer, parses it through the runtime, and folds the request target into a
/// checksum.  Returns the checksum contribution so the parse cannot be elided.
fn dispatchOne(arena: *OrbitArena, template: []const u8, scratch: []u8) u64 {
    @memcpy(scratch[0..template.len], template);

    var req: ?*OrbitRequest = null;
    const consumed = orbit_http_parse_request(arena, scratch.ptr, template.len, &req);

    var hash: u64 = FNV1A_OFFSET;
    if (req) |r| {
        if (r.path) |p| {
            var j: usize = 0;
            while (p[j] != 0) : (j += 1) {
                hash ^= p[j];
                hash *%= FNV1A_PRIME;
            }
        }
    }
    return hash +% @as(u64, consumed);
}

fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const idx = @min((p * sorted.len) / 100, sorted.len - 1);
    return sorted[idx];
}

fn printReport(w: anytype, cfg: Config, median_ns: u64, rps: f64, avg_ns: f64, p50: u64, p95: u64, p99: u64, checksum: u64) !void {
    try w.print("\nHTTP dispatch latency  (Orbit C runtime: src/runtime/http.c)\n", .{});
    try w.print("  request templates:  {d}\n", .{REQUEST_TEMPLATES.len});
    try w.print("  requests per run:   {d}\n", .{cfg.requests_per_run});
    try w.print("  measured runs:      {d}\n", .{cfg.runs});
    try w.print("  warm-up requests:   {d}\n", .{cfg.warmup});
    try w.print("\nMetric                  Value\n", .{});
    try w.print("----------------------  -------------\n", .{});
    try w.print("median run time        {d} ns\n", .{median_ns});
    try w.print("requests/sec           {d:.0}\n", .{rps});
    try w.print("avg latency/request    {d:.1} ns\n", .{avg_ns});
    try w.print("p50 latency            {d} ns\n", .{p50});
    try w.print("p95 latency            {d} ns\n", .{p95});
    try w.print("p99 latency            {d} ns\n", .{p99});
    try w.print("dispatch checksum      0x{x:0>16}\n", .{checksum});
    try w.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = std.Io.File.Writer.init(stdout_file, init.io, &.{});
    const stdout = &stdout_writer.interface;

    const cfg = try parseArgs(try init.minimal.args.toSlice(alloc));
    const cycles_per_ns = calibrateCyclesPerNs(init.io);

    const arena = orbit_arena_create(16 * 1024 * 1024) orelse return error.OutOfMemory;
    defer orbit_arena_destroy(arena);

    var checksum: u64 = 0;

    {
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        for (0..cfg.warmup) |i| {
            checksum +%= dispatchOne(arena, REQUEST_TEMPLATES[i % REQUEST_TEMPLATES.len], &scratch);
            orbit_arena_reset(arena);
        }
    }

    const run_times = try alloc.alloc(u64, cfg.runs);
    for (0..cfg.runs) |run| {
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        const start = std.Io.Clock.Timestamp.now(init.io, .boot);
        for (0..cfg.requests_per_run) |i| {
            checksum +%= dispatchOne(arena, REQUEST_TEMPLATES[i % REQUEST_TEMPLATES.len], &scratch);
            orbit_arena_reset(arena);
        }
        const end = std.Io.Clock.Timestamp.now(init.io, .boot);
        run_times[run] = @intCast(start.durationTo(end).raw.nanoseconds);
    }

    std.sort.heap(u64, run_times, {}, std.sort.asc(u64));
    const median_ns = run_times[cfg.runs / 2];
    const avg_ns = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(cfg.requests_per_run));
    const rps = 1_000_000_000.0 / avg_ns;

    const samples = try alloc.alloc(u64, cfg.requests_per_run);
    {
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        for (0..cfg.requests_per_run) |i| {
            const t0 = rdtsc();
            checksum +%= dispatchOne(arena, REQUEST_TEMPLATES[i % REQUEST_TEMPLATES.len], &scratch);
            orbit_arena_reset(arena);
            const t1 = rdtsc();
            const cycles = t1 - t0;
            samples[i] = @intFromFloat(@as(f64, @floatFromInt(cycles)) / cycles_per_ns);
        }
    }

    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const p50 = percentile(samples, 50);
    const p95 = percentile(samples, 95);
    const p99 = percentile(samples, 99);

    try printReport(stdout, cfg, median_ns, rps, avg_ns, p50, p95, p99, checksum);
}
