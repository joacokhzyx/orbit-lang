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
}
