//! Orbit Formatter Terminal UI Renderer
//! Borderless, modern terminal UI with TrueColor green shimmer gradient effects.

const std = @import("std");

pub const FormatFileStatus = enum {
    formatted,
    clean,
    needs_fmt,
    err,
};

pub const FmtSummary = struct {
    total_files: usize = 0,
    formatted_count: usize = 0,
    clean_count: usize = 0,
    error_count: usize = 0,
    duration_ns: u64 = 0,
    check_mode: bool = false,
};

pub fn renderGreenShimmer(writer: anytype, text: []const u8) !void {
    const len = text.len;
    if (len == 0) return;
    for (text, 0..) |ch, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(if (len > 1) len - 1 else 1));
        // Interpolate from vibrant green (#22c55e -> R=34, G=197, B=94)
        // to soft bright green-white (#f0fdf4 -> R=230, G=253, B=240)
        const r: u8 = @intFromFloat(34.0 + t * (230.0 - 34.0));
        const g: u8 = @intFromFloat(197.0 + t * (255.0 - 197.0));
        const b: u8 = @intFromFloat(94.0 + t * (240.0 - 94.0));
        try writer.print("\x1b[38;2;{d};{d};{d}m{c}", .{ r, g, b, ch });
    }
    try writer.print("\x1b[0m", .{});
}

pub fn renderHeader(writer: anytype, check_mode: bool, version: []const u8) !void {
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try writer.print("\n  {s}Orbit {s}{s}", .{ bold, version, reset });

    if (check_mode) {
        try writer.print(" ", .{});
        try renderGreenShimmer(writer, "(Check Mode)");
    }
    try writer.print("\n\n", .{});
}

pub fn renderItem(writer: anytype, path: []const u8, status: FormatFileStatus) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const dim = "\x1b[90m";
    const reset = "\x1b[0m";

    switch (status) {
        .formatted => {
            try writer.print("  {s}✓ Formatted{s}   {s}\n", .{ green, reset, path });
        },
        .clean => {
            try writer.print("  {s}- Unchanged{s}   {s}\n", .{ dim, reset, path });
        },
        .needs_fmt => {
            try writer.print("  {s}✗ Needs fmt{s}   {s}\n", .{ yellow, reset, path });
        },
        .err => {
            try writer.print("  {s}! Error    {s}   {s}\n", .{ red, reset, path });
        },
    }
}

pub fn renderFooter(writer: anytype, summary: FmtSummary) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const bold = "\x1b[1m";
    const dim_hint = "\x1b[90m";
    const reset = "\x1b[0m";

    const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;

    try writer.print("\n", .{});

    if (summary.check_mode) {
        if (summary.formatted_count > 0 or summary.error_count > 0) {
            try writer.print("  {s}! Status{s}      {s}{d} file(s) require formatting{s} ({d:.1} ms)\n", .{ yellow, reset, bold, summary.formatted_count + summary.error_count, reset, duration_ms });
            try writer.print("  {s}Hint:{s}        Run 'orbit fmt' to format files automatically.\n\n", .{ dim_hint, reset });
        } else {
            try writer.print("  ", .{});
            try renderGreenShimmer(writer, "✓ Status");
            try writer.print("      {s}All {d} file(s) are cleanly formatted{s} ({d:.1} ms)\n\n", .{ bold, summary.total_files, reset, duration_ms });
        }
    } else {
        try writer.print("  {s}+ Total{s}       {d} formatted, {d} unchanged ({d:.1} ms)\n\n", .{ green, reset, summary.formatted_count, summary.clean_count, duration_ms });
    }
}
