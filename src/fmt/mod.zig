//! Orbit Formatter Module Entrypoint (`src/fmt/`)

const std = @import("std");
pub const rules = @import("rules.zig");
pub const diff = @import("diff.zig");
pub const ui = @import("ui.zig");
pub const formatter = @import("formatter.zig");

pub const StdoutWriter = struct {
    pub fn print(self: StdoutWriter, comptime fmt_str: []const u8, args_tuple: anytype) !void {
        _ = self;
        std.debug.print(fmt_str, args_tuple);
    }
};

pub fn runFormatter(io: std.Io, allocator: std.mem.Allocator, target_path: []const u8, version: []const u8, options: rules.FormatterOptions) !void {
    const stdout = StdoutWriter{};
    const t_start = std.Io.Clock.Timestamp.now(io, .awake);

    var summary = ui.FmtSummary{
        .check_mode = options.check_only,
    };

    try ui.renderHeader(stdout, options.check_only, version);

    var cwd = std.Io.Dir.cwd();

    if (cwd.openDir(io, target_path, .{ .iterate = true })) |dir| {
        var mut_dir = dir;
        defer mut_dir.close(io);

        var iterator = mut_dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".orb")) {
                const full_path = try std.fs.path.join(allocator, &.{ target_path, entry.name });
                defer allocator.free(full_path);
                try formatSingleFile(io, allocator, full_path, options, &summary, stdout);
            }
        }
    } else |_| {
        // Single file
        try formatSingleFile(io, allocator, target_path, options, &summary, stdout);
    }

    const t_end = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed = t_start.durationTo(t_end);
    summary.duration_ns = @intCast(@max(0, elapsed.raw.nanoseconds));

    try ui.renderFooter(stdout, summary);

    if (options.check_only and (summary.formatted_count > 0 or summary.error_count > 0)) {
        return error.FormattingRequired;
    }
}

fn formatSingleFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, options: rules.FormatterOptions, summary: *ui.FmtSummary, stdout: anytype) !void {
    summary.total_files += 1;

    var cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, file_path, .{}) catch {
        summary.error_count += 1;
        try ui.renderItem(stdout, file_path, .err);
        return;
    };

    const file_len = file.length(io) catch {
        file.close(io);
        summary.error_count += 1;
        try ui.renderItem(stdout, file_path, .err);
        return;
    };

    const file_content = allocator.alloc(u8, file_len) catch {
        file.close(io);
        summary.error_count += 1;
        try ui.renderItem(stdout, file_path, .err);
        return;
    };
    defer allocator.free(file_content);

    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &read_buf);
    reader.interface.readSliceAll(file_content) catch {
        file.close(io);
        summary.error_count += 1;
        try ui.renderItem(stdout, file_path, .err);
        return;
    };
    file.close(io);

    const formatted_content = formatter.formatSource(allocator, file_content, options) catch {
        summary.error_count += 1;
        try ui.renderItem(stdout, file_path, .err);
        return;
    };
    defer allocator.free(formatted_content);

    // Strip carriage returns \r for OS-agnostic idempotency comparison
    var normalized_orig = std.ArrayListUnmanaged(u8).empty;
    defer normalized_orig.deinit(allocator);
    for (file_content) |b| {
        if (b != '\r') try normalized_orig.append(allocator, b);
    }

    const is_changed = !std.mem.eql(u8, normalized_orig.items, formatted_content);

    if (is_changed) {
        summary.formatted_count += 1;

        if (options.show_diff) {
            const diff_result = try diff.computeDiff(allocator, file_content, formatted_content);
            var mut_diff = diff_result;
            defer mut_diff.deinit(allocator);
            try diff.renderDiff(stdout, file_path, mut_diff, true);
        }

        if (options.check_only) {
            try ui.renderItem(stdout, file_path, .needs_fmt);
        } else if (options.write_in_place) {
            var out_file = try cwd.createFile(io, file_path, .{ .truncate = true });
            defer out_file.close(io);
            var write_buf: [4096]u8 = undefined;
            var writer_state = std.Io.File.Writer.init(out_file, io, &write_buf);
            try writer_state.interface.writeAll(formatted_content);
            try writer_state.flush();
            try ui.renderItem(stdout, file_path, .formatted);
        }
    } else {
        summary.clean_count += 1;
        try ui.renderItem(stdout, file_path, .clean);
    }
}
