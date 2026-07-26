//! Orbit Doctor Module Entrypoint (`src/doctor/`)

const std = @import("std");
pub const ui = @import("ui.zig");
pub const checker = @import("checker.zig");

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

    const t_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed = t_start.durationTo(t_end);
    summary.duration_ns = @intCast(@max(0, elapsed.raw.nanoseconds));

    try ui.renderFooter(stdout, summary);

    if (summary.error_count > 0 and !options.auto_fix) {
        return error.DoctorDiagnosticsFailed;
    }
}
