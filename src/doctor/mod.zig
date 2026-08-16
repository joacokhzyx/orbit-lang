//! Orbit Doctor Module Entrypoint (`src/doctor/`)

const std = @import("std");
pub const ui = @import("ui.zig");
pub const checker = @import("checker.zig");
const ast_analysis = @import("ast_analysis.zig");
const semantic_analysis = @import("semantic_analysis.zig");

pub const StdoutWriter = struct {
    pub fn print(self: StdoutWriter, comptime fmt_str: []const u8, args_tuple: anytype) !void {
        _ = self;
        std.debug.print(fmt_str, args_tuple);
    }
};

pub fn runDoctor(io: std.Io, allocator: std.mem.Allocator, target_dir: []const u8, version: []const u8, options: checker.DoctorOptions) !void {
    const stdout = StdoutWriter{};
    const t_start = std.Io.Clock.Timestamp.now(io, .awake);

    var summary = ui.DoctorSummary{};

    try ui.renderHeader(stdout, version);

    try checker.runDiagnostics(io, allocator, target_dir, &summary, stdout);

    try runStaticAnalysis(io, allocator, target_dir, &summary, stdout);

    const t_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed = t_start.durationTo(t_end);
    summary.duration_ns = @intCast(@max(0, elapsed.raw.nanoseconds));

    try ui.renderFooter(stdout, summary);

    if (summary.error_count > 0 and !options.auto_fix) {
        return error.DoctorDiagnosticsFailed;
    }
}

/// Runs the Layer 2 (AST) and Layer 3 (semantic/IR) static analyses over every
/// `.orb` file in the target directory, rendering each finding and accumulating
/// the per-layer wall-clock time into the Doctor summary.
fn runStaticAnalysis(io: std.Io, allocator: std.mem.Allocator, target_dir: []const u8, summary: *ui.DoctorSummary, writer: anytype) !void {
    try ui.renderCategory(writer, "Semantic & IR Analysis");

    var layer2_ns: u64 = 0;
    var layer3_ns: u64 = 0;

    var cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, target_dir, .{ .iterate = true })) |dir| {
        var mut_dir = dir;
        defer mut_dir.close(io);

        var iterator = mut_dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".orb")) {
                const full_path = try std.fs.path.join(allocator, &.{ target_dir, entry.name });
                defer allocator.free(full_path);

                var file = try cwd.openFile(io, full_path, .{});
                defer file.close(io);

                const file_len = try file.length(io);
                const source = try allocator.alloc(u8, file_len);
                defer allocator.free(source);

                var read_buf: [8192]u8 = undefined;
                var reader = std.Io.File.Reader.init(file, io, &read_buf);
                try reader.interface.readSliceAll(source);

                var t2_start = std.Io.Clock.Timestamp.now(io, .awake);
                const layer2 = try ast_analysis.analyze(allocator, source, full_path);
                const t2_end = std.Io.Clock.Timestamp.now(io, .awake);
                defer freeFindings(allocator, layer2);
                layer2_ns += @intCast(@max(0, t2_start.durationTo(t2_end).raw.nanoseconds));

                var t3_start = std.Io.Clock.Timestamp.now(io, .awake);
                const layer3 = try semantic_analysis.analyze(allocator, source, full_path);
                const t3_end = std.Io.Clock.Timestamp.now(io, .awake);
                defer freeFindings(allocator, layer3);
                layer3_ns += @intCast(@max(0, t3_start.durationTo(t3_end).raw.nanoseconds));

                for (layer2) |f| try renderFinding(writer, summary, f);
                for (layer3) |f| try renderFinding(writer, summary, f);
            }
        }
    } else |_| {}

    summary.layer2_ast_ns = layer2_ns;
    summary.layer3_semantic_ns = layer3_ns;

    try writer.print("\n", .{});
}

fn renderFinding(writer: anytype, summary: *ui.DoctorSummary, finding: ui.Finding) !void {
    summary.total_checks += 1;
    switch (finding.severity) {
        .ok => summary.ok_count += 1,
        .warning => summary.warning_count += 1,
        .err => summary.error_count += 1,
    }
    var buf: [512]u8 = undefined;
    const details = try std.fmt.bufPrint(&buf, "{s}:{d}  {s}", .{ finding.file, finding.line, finding.message });
    try ui.renderItem(writer, .{
        .category = "Static Analysis",
        .label = finding.code,
        .details = details,
        .severity = finding.severity,
    });
}

fn freeFindings(allocator: std.mem.Allocator, findings: []const ui.Finding) void {
    for (findings) |f| {
        allocator.free(f.category);
        allocator.free(f.code);
        allocator.free(f.file);
        allocator.free(f.message);
    }
    allocator.free(findings);
}
