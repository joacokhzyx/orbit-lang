//! Orbit Doctor Terminal UI Renderer
//! Borderless, modern terminal UI with TrueColor red shimmer gradient effects for Doctor diagnostics.

const std = @import("std");

pub const DiagnosticSeverity = enum {
    ok,
    warning,
    err,
};

pub const DiagnosticItem = struct {
    category: []const u8,
    label: []const u8,
    details: []const u8,
    severity: DiagnosticSeverity,
};

pub const DoctorSummary = struct {
    total_checks: usize = 0,
    ok_count: usize = 0,
    warning_count: usize = 0,
    error_count: usize = 0,
    duration_ns: u64 = 0,
};

pub fn renderRedShimmer(writer: anytype, text: []const u8) !void {
    const len = text.len;
    if (len == 0) return;
    for (text, 0..) |ch, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(if (len > 1) len - 1 else 1));
        // Crimson Red (#ef4444 -> R=239, G=68, B=68) to Soft Bright Rose-White (#fff1f2 -> R=255, G=241, B=242)
        const r: u8 = @intFromFloat(239.0 + t * (255.0 - 239.0));
        const g: u8 = @intFromFloat(68.0 + t * (241.0 - 68.0));
        const b: u8 = @intFromFloat(68.0 + t * (242.0 - 68.0));
        try writer.print("\x1b[38;2;{d};{d};{d}m{c}", .{ r, g, b, ch });
    }
    try writer.print("\x1b[0m", .{});
}

pub fn renderHeader(writer: anytype, version: []const u8) !void {
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try writer.print("\n  {s}Orbit {s}{s} ", .{ bold, version, reset });
    try renderRedShimmer(writer, "(Doctor)");
    try writer.print("\n\n", .{});
}

pub fn renderCategory(writer: anytype, category_name: []const u8) !void {
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try writer.print("  {s}{s}{s}\n", .{ bold, category_name, reset });
}

pub fn renderItem(writer: anytype, item: DiagnosticItem) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const reset = "\x1b[0m";

    switch (item.severity) {
        .ok => {
            try writer.print("  {s}✓{s} {s:<22} {s}\n", .{ green, reset, item.label, item.details });
        },
        .warning => {
            try writer.print("  {s}!{s} {s:<22} {s}\n", .{ yellow, reset, item.label, item.details });
        },
        .err => {
            try writer.print("  {s}✗{s} {s:<22} {s}\n", .{ red, reset, item.label, item.details });
        },
    }
}

pub fn renderFooter(writer: anytype, summary: DoctorSummary) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;

    try writer.print("\n", .{});

    if (summary.error_count > 0) {
        try writer.print("  {s}✗ Status{s}      {s}{d} error(s), {d} warning(s) found{s} ({d:.1} ms)\n\n", .{ red, reset, bold, summary.error_count, summary.warning_count, reset, duration_ms });
    } else if (summary.warning_count > 0) {
        try writer.print("  {s}! Status{s}      {s}All systems operational ({d} warning(s)){s} ({d:.1} ms)\n\n", .{ yellow, reset, bold, summary.warning_count, reset, duration_ms });
    } else {
        try writer.print("  {s}✓ Status{s}      {s}All systems operational (0 errors, 0 warnings){s} ({d:.1} ms)\n\n", .{ green, reset, bold, reset, duration_ms });
    }
}
