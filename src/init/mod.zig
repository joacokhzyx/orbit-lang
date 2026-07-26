//! Orbit Init Module Entrypoint (`src/init/`)

const std = @import("std");
pub const templates = @import("templates.zig");
pub const ui = @import("ui.zig");
pub const scaffold = @import("scaffold.zig");

pub const StdoutWriter = struct {
    pub fn print(self: StdoutWriter, comptime fmt_str: []const u8, args_tuple: anytype) !void {
        _ = self;
        std.debug.print(fmt_str, args_tuple);
    }
};

pub fn runInit(io: std.Io, allocator: std.mem.Allocator, project_name: []const u8, version: []const u8, options: scaffold.InitOptions) !void {
    const stdout = StdoutWriter{};
    const t_start = std.Io.Clock.Timestamp.now(io, .awake);

    var summary = ui.InitSummary{
        .project_name = project_name,
        .preset_name = @tagName(options.preset),
    };

    try ui.renderHeader(stdout, version);

    try scaffold.scaffoldProject(io, allocator, project_name, options, &summary, stdout);

    const t_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed = t_start.durationTo(t_end);
    summary.duration_ns = @intCast(@max(0, elapsed.raw.nanoseconds));

    try ui.renderFooter(stdout, summary);
}
