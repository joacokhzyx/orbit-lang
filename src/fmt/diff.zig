//! Orbit Formatter Diff Engine
//! Generates unified diffs with ANSI color highlights for terminal output.

const std = @import("std");

pub const DiffChunk = struct {
    line_number: usize,
    original: []const u8,
    formatted: []const u8,
};

pub const DiffResult = struct {
    chunks: std.ArrayListUnmanaged(DiffChunk),
    additions: usize,
    deletions: usize,

    pub fn init(_: std.mem.Allocator) DiffResult {
        return .{
            .chunks = .empty,
            .additions = 0,
            .deletions = 0,
        };
    }

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        self.chunks.deinit(allocator);
    }
};

pub fn computeDiff(allocator: std.mem.Allocator, original: []const u8, formatted: []const u8) !DiffResult {
    var result = DiffResult.init(allocator);

    var orig_lines = std.mem.splitScalar(u8, original, '\n');
    var fmt_lines = std.mem.splitScalar(u8, formatted, '\n');

    var line_num: usize = 1;
    while (true) {
        const orig_opt = orig_lines.next();
        const fmt_opt = fmt_lines.next();

        if (orig_opt == null and fmt_opt == null) break;

        const orig = orig_opt orelse "";
        const fmt = fmt_opt orelse "";

        if (!std.mem.eql(u8, orig, fmt)) {
            try result.chunks.append(allocator, .{
                .line_number = line_num,
                .original = orig,
                .formatted = fmt,
            });
            if (orig.len > 0) result.deletions += 1;
            if (fmt.len > 0) result.additions += 1;
        }

        line_num += 1;
    }

    return result;
}

pub fn renderDiff(writer: anytype, file_path: []const u8, diff: DiffResult, color: bool) !void {
    const red = if (color) "\x1b[31m" else "";
    const green = if (color) "\x1b[32m" else "";
    const cyan = if (color) "\x1b[36m" else "";
    const bold = if (color) "\x1b[1m" else "";
    const reset = if (color) "\x1b[0m" else "";

    try writer.print("\n  {s}── Diff: {s}{s}{s}\n\n", .{ cyan, bold, file_path, reset });

    for (diff.chunks.items) |chunk| {
        if (chunk.original.len > 0) {
            try writer.print("  {s}-  {s}{s}\n", .{ red, chunk.original, reset });
        }
        if (chunk.formatted.len > 0) {
            try writer.print("  {s}+  {s}{s}\n", .{ green, chunk.formatted, reset });
        }
    }

    try writer.print("\n  {s}+ Summary     {d} additions, {d} deletions{s}\n\n", .{ bold, diff.additions, diff.deletions, reset });
}
