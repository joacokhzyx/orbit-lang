const std = @import("std");

pub const DiagnosticLevel = enum {
    error_level,
    warning,
    info,
};

pub const Diagnostic = struct {
    level: DiagnosticLevel,
    code: []const u8,
    message: []const u8,
    line: usize,
    col: usize,
    file_path: []const u8,
    file_source: []const u8,
    
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

pub const DiagnosticReporter = struct {
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    allocator: std.mem.Allocator,
    error_count: usize,
    warning_count: usize,
    
    pub fn init(allocator: std.mem.Allocator) DiagnosticReporter {
        return .{
            .diagnostics = .empty,
            .allocator = allocator,
            .error_count = 0,
            .warning_count = 0,
        };
    }
    
    pub fn deinit(self: *DiagnosticReporter) void {
        self.diagnostics.deinit(self.allocator);
    }
    
    pub fn reportError(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.error_level, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
        self.error_count += 1;
    }
    
    pub fn reportWarning(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.warning, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
        self.warning_count += 1;
    }
    
    pub fn reportInfo(self: *DiagnosticReporter, code: []const u8, message: []const u8, token: @import("../token.zig").Token) !void {
        const diag = Diagnostic.init(.info, code, message, token.loc.line, token.loc.col, token.file_path, token.file_source);
        try self.diagnostics.append(self.allocator, diag);
    }
    
    pub fn hasErrors(self: *DiagnosticReporter) bool {
        return self.error_count > 0;
    }
    
    pub fn hasWarnings(self: *DiagnosticReporter) bool {
        return self.warning_count > 0;
    }
    
    pub fn clear(self: *DiagnosticReporter) void {
        self.diagnostics.clearRetainingCapacity();
        self.error_count = 0;
        self.warning_count = 0;
    }
    
    pub fn getDiagnostics(self: *DiagnosticReporter) []const Diagnostic {
        return self.diagnostics.items;
    }
};
