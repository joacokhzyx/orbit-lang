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

    const bench_step = b.step("bench", "Run the full Orbit benchmark suite");
    const run_harness = b.addRunArtifact(harness);
    // Forward extra args: zig build bench -- --suite compute --lang go
    run_harness.addArg("--bench-dir");
    run_harness.addDirectoryArg(b.path("."));
    if (b.args) |args| {
        run_harness.addArgs(args);
    }
    bench_step.dependOn(&run_harness.step);
}
