//! Diagnostic reporting for the Orbit semantic analyser.
//! Provides `Diagnostic`, a single structured error/warning/info message,
//! and `DiagnosticReporter`, a collector that accumulates diagnostics during
//! semantic analysis and exposes summary counts for quick error checking.

const std = @import("std");

/// Severity level of a diagnostic message.
pub const DiagnosticLevel = enum {
    error_level,
    warning,
    info,
};

/// A single diagnostic message emitted during semantic analysis.
/// Carries the severity level, a short error code, a human-readable
/// message, and the source location (file, line, column) where the
/// issue was detected.
pub const Diagnostic = struct {
    level: DiagnosticLevel,
    code: []const u8,
    message: []const u8,
    line: usize,
    col: usize,
    file_path: []const u8,
    file_source: []const u8,

    /// Creates a `Diagnostic` with all fields initialised from the given
    /// arguments.  The strings are borrowed — the caller must ensure they
    /// outlive the diagnostic.
    pub fn init(level: DiagnosticLevel, code: []const u8, message: []const u8, line: usize, col: usize, file_path: []const u8, file_source: []const u8) Diagnostic {
        return .{
            .level = level,
            .code = code,
            .message = message,
            .line = line,
            .col = col,
            .file_path = file_path,
            .file_source = file_source,
        };
    }
};

/// Collects diagnostics produced during semantic analysis and tracks
/// error/warning counts for fast summary checks.
pub const DiagnosticReporter = struct {
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    allocator: std.mem.Allocator,
    error_count: usize,
    warning_count: usize,

    /// Creates an empty `DiagnosticReporter` backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) DiagnosticReporter {
        return .{
            .diagnostics = .empty,
            .allocator = allocator,
            .error_count = 0,
            .warning_count = 0,
        };
    }

    /// Releases the internal diagnostic list.
    pub fn deinit(self: *DiagnosticReporter) void {
        self.diagnostics.deinit(self.allocator);
    }

    /// Appends an error-level diagnostic for `token`'s source location and
    /// increments the error counter.
    pub fn reportError(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.error_level, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
        self.error_count += 1;
    }

    /// Appends a warning-level diagnostic for `token`'s source location and
    /// increments the warning counter.
    pub fn reportWarning(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.warning, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
        self.warning_count += 1;
    }

    /// Appends an informational diagnostic for `token`'s source location.
    /// Info messages do not affect the error or warning counters.
    pub fn reportInfo(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.info, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
    }

    /// Returns `true` if at least one error-level diagnostic has been recorded.
    pub fn hasErrors(self: *DiagnosticReporter) bool {
        return self.error_count > 0;
    }

    /// Returns `true` if at least one warning-level diagnostic has been recorded.
    pub fn hasWarnings(self: *DiagnosticReporter) bool {
        return self.warning_count > 0;
    }

    /// Clears all accumulated diagnostics and resets the error/warning counters.
    pub fn clear(self: *DiagnosticReporter) void {
        self.diagnostics.clearRetainingCapacity();
        self.error_count = 0;
        self.warning_count = 0;
    }

    /// Returns a read-only slice of all accumulated diagnostics in insertion order.
    pub fn getDiagnostics(self: *DiagnosticReporter) []const Diagnostic {
        return self.diagnostics.items;
    }
};
