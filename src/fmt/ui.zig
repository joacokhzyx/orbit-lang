//! Orbit Formatter Terminal UI Renderer
//! Formats stunning ANSI terminal boxes and progress status reports.

const std = @import("std");

pub const FormatFileStatus = enum {
    formatted,
    clean,
    needs_fmt,
    err,
};

pub const FileReport = struct {
    path: []const u8,
    status: FormatFileStatus,
    duration_ns: u64 = 0,
};

pub const FmtSummary = struct {
    total_files: usize = 0,
    formatted_count: usize = 0,
    clean_count: usize = 0,
    error_count: usize = 0,
    duration_ns: u64 = 0,
    check_mode: bool = false,
};

pub fn renderHeader(writer: anytype, check_mode: bool) !void {
    const title = if (check_mode) "Orbit Formatter (Check Mode)" else "Orbit Formatter";
    try writer.print("\n  ┌── {s} ─────────────────────────────────────────────┐\n  │                                                                │\n", .{title});
}

pub fn renderItem(writer: anytype, path: []const u8, status: FormatFileStatus) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const dim = "\x1b[90m";
    const reset = "\x1b[0m";

    switch (status) {
        .formatted => {
            try writer.print("  │  {s}✓ Formatted{s}   {s}\n", .{ green, reset, path });
        },
        .clean => {
            try writer.print("  │  {s}- Unchanged{s}   {s}\n", .{ dim, reset, path });
        },
        .needs_fmt => {
            try writer.print("  │  {s}✗ Needs fmt{s}   {s}\n", .{ yellow, reset, path });
        },
        .err => {
            try writer.print("  │  {s}! Error    {s}   {s}\n", .{ red, reset, path });
        },
    }
}

pub fn renderFooter(writer: anytype, summary: FmtSummary) !void {
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    const duration_ms = @as(f64, @floatFromInt(summary.duration_ns)) / 1_000_000.0;

    try writer.print("  │                                                                │\n", .{});

    if (summary.check_mode) {
        if (summary.formatted_count > 0 or summary.error_count > 0) {
            try writer.print("  │  {s}! Status{s}      {s}{d} file(s) require formatting{s} ({d:.1} ms)\n", .{ yellow, reset, bold, summary.formatted_count + summary.error_count, reset, duration_ms });
            try writer.print("  │  {s}Hint:{s}        Run 'orbit fmt' to format files automatically.\n", .{ dim_hint, reset });
        } else {
            try writer.print("  │  {s}✓ Status{s}      {s}All {d} file(s) are cleanly formatted{s} ({d:.1} ms)\n", .{ green, reset, bold, summary.total_files, reset, duration_ms });
        }
    } else {
        try writer.print("  │  {s}+ Total{s}       {d} formatted, {d} unchanged ({d:.1} ms)\n", .{ green, reset, summary.formatted_count, summary.clean_count, duration_ms });
    }

    try writer.print("  └────────────────────────────────────────────────────────────────┘\n\n", .{});
}

const dim_hint = "\x1b[90m";
