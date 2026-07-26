//! Orbit Init Terminal UI Renderer
//! Borderless, modern terminal UI with TrueColor cyan shimmer gradient effects for Init scaffolding.

const std = @import("std");

pub const InitSummary = struct {
    project_name: []const u8,
    preset_name: []const u8,
    files_created: usize = 0,
    duration_ns: u64 = 0,
};

pub fn renderCyanShimmer(writer: anytype, text: []const u8) !void {
    const len = text.len;
    if (len == 0) return;
    for (text, 0..) |ch, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(if (len > 1) len - 1 else 1));
        // Electric Cyan (#06b6d4 -> R=6, G=182, B=212) to Soft Bright Cyan-White (#ecfeff -> R=236, G=254, B=255)
        const r: u8 = @intFromFloat(6.0 + t * (236.0 - 6.0));
        const g: u8 = @intFromFloat(182.0 + t * (254.0 - 182.0));
        const b: u8 = @intFromFloat(212.0 + t * (255.0 - 212.0));
        try writer.print("\x1b[38;2;{d};{d};{d}m{c}", .{ r, g, b, ch });
    }
    try writer.print("\x1b[0m", .{});
}

pub fn renderHeader(writer: anytype, version: []const u8) !void {
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try writer.print("\n  {s}Orbit {s}{s} ", .{ bold, version, reset });
    try renderCyanShimmer(writer, "(Init)");
    try writer.print("\n\n", .{});
}

pub fn renderStep(writer: anytype, action: []const u8, path: []const u8) !void {
    const green = "\x1b[32m";
    const reset = "\x1b[0m";

    try writer.print("  {s}✓ {s:<12}{s} {s}\n", .{ green, action, reset, path });
}

pub fn renderFooter(writer: anytype, summary: InitSummary) !void {
    const green = "\x1b[32m";
    const bold = "\x1b[1m";
    const dim = "\x1b[90m";
    const reset = "\x1b[0m";

    const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;

    try writer.print("\n", .{});
    try writer.print("  {s}✓ Status{s}      {s}Initialized '{s}' ({s} preset) with {d} files{s} ({d:.1} ms)\n", .{ green, reset, bold, summary.project_name, summary.preset_name, summary.files_created, reset, duration_ms });
    try writer.print("  {s}Next steps:{s}  Run 'orbit dev main.orb' or 'orbit build main.orb --backend=c'\n\n", .{ dim, reset });
}
