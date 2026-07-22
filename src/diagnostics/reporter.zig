//! Orbit Native Error Diagnostics & Reporting Engine
//! Renders beautiful, verbose, ANSI-colored diagnostic cards for Orbit source errors.

const std = @import("std");
const style = @import("../terminal/style.zig");
const symbols = @import("../terminal/symbols.zig");

pub const DiagnosticSeverity = enum {
    err,
    warning,
    info,
};

pub const Diagnostic = struct {
    code: []const u8, // e.g. "E0204"
    severity: DiagnosticSeverity = .err,
    message: []const u8,
    file_path: []const u8,
    line: usize,
    column: usize,
    source_line: []const u8,
    offending_span: []const u8,
    help: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const DiagnosticBag = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticBag {
        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(Diagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *DiagnosticBag) void {
        self.diagnostics.deinit();
    }

    pub fn addError(
        self: *DiagnosticBag,
        code: []const u8,
        message: []const u8,
        file_path: []const u8,
        line: usize,
        column: usize,
        source_line: []const u8,
        offending_span: []const u8,
        help: ?[]const u8,
        note: ?[]const u8,
    ) !void {
        try self.diagnostics.append(.{
            .code = code,
            .severity = .err,
            .message = message,
            .file_path = file_path,
            .line = line,
            .column = column,
            .source_line = source_line,
            .offending_span = offending_span,
            .help = help,
            .note = note,
        });
    }

    pub fn hasErrors(self: *const DiagnosticBag) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) return true;
        }
        return false;
    }

    pub fn renderAll(self: *const DiagnosticBag, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            try renderDiagnostic(diag, writer);
        }
    }
};

pub fn renderDiagnostic(diag: Diagnostic, writer: anytype) !void {
    const bold_err = style.getEsc(.bold_err);
    const bold_white = style.getEsc(.bold_white);
    const muted = style.getEsc(.muted);
    const bold_primary = style.getEsc(.bold_primary);
    const reset = style.getReset();

    try writer.print("\n", .{});
    try writer.print("{s}┌── Orbit Compiler Error [{s}] ───────────────────────────────────┐{s}\n", .{ bold_err, diag.code, reset });
    try writer.print("{s}│{s}\n", .{ bold_err, reset });
    try writer.print("{s}│{s}  {s}error[{s}]: {s}{s}{s}\n", .{ bold_err, reset, bold_err, diag.code, bold_white, diag.message, reset });
    try writer.print("{s}│{s}    {s}--> {s}:{d}:{d}{s}\n", .{ bold_err, reset, muted, diag.file_path, diag.line, diag.column, reset });
    try writer.print("{s}│{s}     {s}|{s}\n", .{ bold_err, reset, muted, reset });

    if (diag.source_line.len > 0) {
        try writer.print("{s}│{s}  {s}{d: >3} |{s} {s}\n", .{ bold_err, reset, muted, diag.line, reset, diag.source_line });

        // Calculate caret padding
        var caret_pad: usize = 0;
        if (diag.column > 0) caret_pad = diag.column - 1;

        var caret_len = diag.offending_span.len;
        if (caret_len == 0) caret_len = 1;

        try writer.print("{s}│{s}      {s}|{s} ", .{ bold_err, reset, muted, reset });
        var i: usize = 0;
        while (i < caret_pad) : (i += 1) {
            try writer.print(" ", .{});
        }
        try writer.print("{s}", .{bold_err});
        var j: usize = 0;
        while (j < caret_len) : (j += 1) {
            try writer.print("^", .{});
        }
        try writer.print(" {s}{s}\n", .{ diag.message, reset });
    }

    try writer.print("{s}│{s}     {s}|{s}\n", .{ bold_err, reset, muted, reset });

    if (diag.help) |h| {
        try writer.print("{s}│{s}     {s}= help:{s} {s}{s}{s}\n", .{ bold_err, reset, bold_primary, reset, bold_white, h, reset });
    }

    if (diag.note) |n| {
        try writer.print("{s}│{s}     {s}= note:{s} {s}{s}{s}\n", .{ bold_err, reset, muted, reset, muted, n, reset });
    }

    try writer.print("{s}│{s}\n", .{ bold_err, reset });
    try writer.print("{s}└────────────────────────────────────────────────────────────────┘{s}\n\n", .{ bold_err, reset });
}
