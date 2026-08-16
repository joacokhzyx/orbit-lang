const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const harness = b.addExecutable(.{
        .name = "bench_harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Options forwarded to the harness (replaces the removed b.args API)
    const suite_opt = b.option([]const u8, "suite", "Suite to run: all, compute, http, death (default: all)");
    const lang_opt = b.option([]const u8, "lang", "Comma-separated language filter, e.g. go,rust");
    const no_color = b.option(bool, "no-color", "Disable ANSI colour output") orelse false;

    const bench_step = b.step("bench", "Run the full Orbit benchmark suite");
    const run_harness = b.addRunArtifact(harness);

    run_harness.addArg("--bench-dir");
    run_harness.addDirectoryArg(b.path("."));

    if (suite_opt) |suite| {
        run_harness.addArgs(&.{ "--suite", suite });
    }
    if (lang_opt) |lang| {
        run_harness.addArgs(&.{ "--lang", lang });
    }
    if (no_color) {
        run_harness.addArg("--no-color");
    }

    bench_step.dependOn(&run_harness.step);

    // ── HTTP dispatch latency micro-benchmark (BENCH-0) ──────────────────
    // Standalone benchmark for the C runtime's per-request parse/dispatch
    // path in src/runtime/http.c.  Linked directly against the C runtime via
    // the shim in http_dispatch_latency_shim.c (which also supplies the TLS
    // oracle-session backing store normally provided by src/runtime/oracle.c).
    // ReleaseFast is hardcoded: latency measurements in Debug builds are
    // not representative of the runtime's dispatch cost.
    const dispatch = b.addExecutable(.{
        .name = "bench_http_dispatch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("http_dispatch_latency.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });

    dispatch.root_module.addCSourceFile(.{
        .file = b.path("http_dispatch_latency_shim.c"),
        .flags = &.{ "-O2", "-std=c11" },
    });
    if (target.result.os.tag == .windows) {
        dispatch.root_module.linkSystemLibrary("ws2_32", .{});
    }

    const bench_http_dispatch_step = b.step("bench-http-dispatch", "Run the HTTP dispatch latency micro-benchmark");
    const run_dispatch = b.addRunArtifact(dispatch);
    run_dispatch.addPassthruArgs();
    bench_http_dispatch_step.dependOn(&run_dispatch.step);

    // ── Dynamic cross-language HTTP benchmark ────────────────────────────
    // Orbit vs Go vs Rust vs Node vs C over real sockets (hello-world
    // endpoint), loaded with `hey`.  Requires python, go, cargo, node and
    // hey on PATH.  Relative ranking is meaningful; absolute numbers are
    // environment-dependent, so run on a quiet machine and compare within
    // a single session.
    const dynamic_step = b.step("bench-http-dynamic", "Run the dynamic cross-language HTTP benchmark (Orbit vs Go/Rust/Node/C)");
    const run_dynamic = b.addSystemCommand(&.{ "python", "dynamic/run_dynamic_bench.py" });
    run_dynamic.setCwd(b.path("."));
    dynamic_step.dependOn(&run_dynamic.step);
}
