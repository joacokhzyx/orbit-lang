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
    
    pub fn init(level: DiagnosticLevel, code: []const u8, message: []const u8, line: usize, col: usize) Diagnostic {
        return .{
            .level = level,
            .code = code,
            .message = message,
            .line = line,
            .col = col,
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
            .diagnostics = .{},
            .allocator = allocator,
            .error_count = 0,
            .warning_count = 0,
        };
    }
    
    pub fn deinit(self: *DiagnosticReporter) void {
        self.diagnostics.deinit(self.allocator);
    }
    
    pub fn reportError(self: *DiagnosticReporter, code: []const u8, message: []const u8, line: usize, col: usize) !void {
        const diag = Diagnostic.init(.error_level, code, message, line, col);
        try self.diagnostics.append(self.allocator, diag);
        self.error_count += 1;
    }
    
    pub fn reportWarning(self: *DiagnosticReporter, code: []const u8, message: []const u8, line: usize, col: usize) !void {
        const diag = Diagnostic.init(.warning, code, message, line, col);
        try self.diagnostics.append(self.allocator, diag);
        self.warning_count += 1;
    }
    
    pub fn reportInfo(self: *DiagnosticReporter, code: []const u8, message: []const u8, line: usize, col: usize) !void {
        const diag = Diagnostic.init(.info, code, message, line, col);
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
