//! Terminal layout primitives for the Orbit compiler output layer.
//! Provides utilities for measuring visible text width (stripping ANSI
//! escape sequences), selecting Unicode or ASCII border characters, and
//! rendering titled panels to any `std.io` writer.

const std = @import("std");
const capabilities = @import("capabilities.zig");

/// Calculates the visible display width of `text` in terminal columns,
/// excluding any ANSI escape sequences embedded in the string.
/// Multi-byte UTF-8 sequences are counted as one column each.
pub fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b') {
            while (i < text.len and text[i] != 'm' and text[i] != 'K' and text[i] != 'H' and text[i] != 'J') : (i += 1) {}
            if (i < text.len) i += 1;
        } else {
            const byte = text[i];
            const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            width += 1;
            i += len;
        }
    }
    return width;
}

/// A set of border-drawing characters used by panel and rule helpers.
/// Either Unicode box-drawing characters or plain ASCII, depending on
/// terminal capabilities.
pub const Border = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    v: []const u8,
};

/// Returns the appropriate `Border` for the current terminal.
/// Uses Unicode box-drawing characters when `has_unicode` is `true`,
/// falling back to `+`, `-`, and `|` otherwise.
pub fn getBorder() Border {
    const unicode = capabilities.get().has_unicode;
    if (unicode) {
        return .{
            .tl = "┌",
            .tr = "┐",
            .bl = "└",
            .br = "┘",
            .h = "─",
            .v = "│",
        };
    } else {
        return .{
            .tl = "+",
            .tr = "+",
            .bl = "+",
            .br = "+",
            .h = "-",
            .v = "|",
        };
    }
}

/// Writes a horizontal rule of `width` border-characters to `writer`.
pub fn horizontalRule(writer: anytype, width: usize) !void {
    const b = getBorder();
    var i: usize = 0;
    while (i < width) : (i += 1) {
        try writer.writeAll(b.h);
    }
}

/// Renders a titled box panel to `writer`.
///
/// The panel is `width` characters wide (interior) and displays `title` in
/// bold on the top border when colour is enabled.  `content` is split on
/// newlines and each line is padded to fill the interior width.
pub fn renderPanel(writer: anytype, title: []const u8, content: []const u8, width: usize) !void {
    const b = getBorder();
    const caps = capabilities.get();

    const bold_esc = if (caps.has_color) "\x1b[1m" else "";
    const reset_esc = if (caps.has_color) "\x1b[0m" else "";

    // Top border with title
    try writer.writeAll(b.tl);
    try writer.writeAll(b.h);
    if (title.len > 0) {
        try writer.print(" {s}{s}{s} ", .{ bold_esc, title, reset_esc });
        const used = 3 + title.len;
        if (width > used) {
            var i: usize = 0;
            const remaining = width - used;
            while (i < remaining) : (i += 1) {
                try writer.writeAll(b.h);
            }
        }
    } else {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll(b.h);
        }
    }
    try writer.writeAll(b.tr);
    try writer.writeAll("\n");

    // Content lines
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        try writer.writeAll(b.v);
        try writer.writeAll(" ");
        try writer.writeAll(line);

        const line_len = visibleWidth(line);
        const total_inner_width = width + 1; // spacing
        if (total_inner_width > line_len + 1) {
            var i: usize = 0;
            const pad = total_inner_width - (line_len + 1);
            while (i < pad) : (i += 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll(b.v);
        try writer.writeAll("\n");
    }

    // Bottom border
    try writer.writeAll(b.bl);
    var i: usize = 0;
    while (i < width + 1) : (i += 1) {
        try writer.writeAll(b.h);
    }
    try writer.writeAll(b.br);
    try writer.writeAll("\n");
}

/// Write raw bytes directly to stderr, bypassing Zig's Io.Threaded streaming
/// writer which uses WriteFileGather on Windows and requires page-aligned buffers.
/// Plain WriteFile works with any memory layout.
fn writeStderr(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (@import("builtin").os.tag == .windows) {
        const windows = std.os.windows;
        const h = windows.kernel32.GetStdHandle(windows.STD_ERROR_HANDLE) orelse return;
        if (h == windows.INVALID_HANDLE_VALUE) return;
        var written: windows.DWORD = 0;
        _ = windows.kernel32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
    } else {
        var idx: usize = 0;
        while (idx < bytes.len) {
            const n = std.posix.write(std.posix.STDERR_FILENO, bytes[idx..]) catch break;
            idx += n;
        }
    }
}

pub const DebugWriter = struct {
    pub fn writeAll(self: DebugWriter, bytes: []const u8) !void {
        _ = self;
        writeStderr(bytes);
    }
    pub fn print(self: DebugWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        var buf: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        writeStderr(s);
    }
};

var stderr_mutex = std.Thread.Mutex{};

pub fn lockStderr() void {
    stderr_mutex.lock();
}

pub fn unlockStderr() void {
    stderr_mutex.unlock();
}

pub fn renderBoxCardStderr(title: []const u8, lines: []const []const u8, width: usize) void {
    stderr_mutex.lock();
    defer stderr_mutex.unlock();
    const w = DebugWriter{};
    renderBoxCard(w, title, lines, width) catch {};
}

pub fn renderGradientTextBuf(buf: []u8, text: []const u8, start_rgb: [3]u8, end_rgb: [3]u8) []const u8 {
    const caps = capabilities.get();
    if (!caps.has_color) return text;
    const total_cols = visibleWidth(text);
    if (total_cols == 0) return text;

    var pos: usize = 0;
    var col_idx: usize = 0;
    var byte_idx: usize = 0;
    while (byte_idx < text.len) {
        if (text[byte_idx] == '\x1b') {
            const ansi_start = byte_idx;
            while (byte_idx < text.len and text[byte_idx] != 'm' and text[byte_idx] != 'K') : (byte_idx += 1) {}
            if (byte_idx < text.len) byte_idx += 1;
            const slice = text[ansi_start..byte_idx];
            if (pos + slice.len <= buf.len) {
                @memcpy(buf[pos .. pos + slice.len], slice);
                pos += slice.len;
            }
            continue;
        }

        const char_len = std.unicode.utf8ByteSequenceLength(text[byte_idx]) catch 1;
        const char_slice = text[byte_idx .. byte_idx + char_len];

        const t = if (total_cols > 1) @as(f32, @floatFromInt(col_idx)) / @as(f32, @floatFromInt(total_cols - 1)) else 0.0;
        const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(start_rgb[0])) * (1.0 - t) + @as(f32, @floatFromInt(end_rgb[0])) * t));
        const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(start_rgb[1])) * (1.0 - t) + @as(f32, @floatFromInt(end_rgb[1])) * t));
        const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(start_rgb[2])) * (1.0 - t) + @as(f32, @floatFromInt(end_rgb[2])) * t));

        const formatted = std.fmt.bufPrint(buf[pos..], "\x1b[38;2;{d};{d};{d}m{s}", .{ r, g, b, char_slice }) catch break;
        pos += formatted.len;
        col_idx += 1;
        byte_idx += char_len;
    }
    const reset_str = "\x1b[0m";
    if (pos + reset_str.len <= buf.len) {
        @memcpy(buf[pos .. pos + reset_str.len], reset_str);
        pos += reset_str.len;
    }
    return buf[0..pos];
}

pub const Spinner = struct {
    message: []const u8,
    active: std.atomic.Value(bool),
    thread: ?std.Thread,

    const frames_unicode = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const frames_ascii = [_][]const u8{ "|", "/", "-", "\\" };

    /// Create a Spinner in-place. Call spawn() after the struct is in its
    /// final memory location (caller's stack) to avoid dangling-pointer UB.
    pub fn init(message: []const u8) Spinner {
        return .{
            .message = message,
            .active = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    /// Launch the animation thread. Must be called on a stable (non-moving)
    /// pointer — i.e. after the Spinner is stored in the caller's variable.
    pub fn spawn(self: *Spinner) !void {
        self.active.store(true, .monotonic);
        const caps = capabilities.get();
        if (caps.is_stdout_tty or caps.is_stderr_tty) {
            self.thread = try std.Thread.spawn(.{}, spinLoop, .{self});
        }
    }

    fn spinLoop(self: *Spinner) void {
        const caps = capabilities.get();
        const frames = if (caps.has_unicode) &frames_unicode else &frames_ascii;
        const cyan = if (caps.has_color) "\x1b[1;36m" else "";
        const dim = if (caps.has_color) "\x1b[2;90m" else "";
        const reset = if (caps.has_color) "\x1b[0m" else "";

        var i: usize = 0;
        const is_windows = @import("builtin").os.tag == .windows;
        while (self.active.load(.monotonic)) {
            const frame = frames[i % frames.len];
            // Build the line in a stack buffer then write via raw syscall —
            // avoids Zig master's Io.Threaded path (WriteFileGather requires
            // page-aligned buffers and crashes with ERROR_NOACCESS on Windows).
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "\r\x1b[2K  {s}{s}{s} {s}{s}{s}", .{
                cyan, frame, reset, dim, self.message, reset,
            }) catch "\r\x1b[2K  * Compiling...";
            {
                stderr_mutex.lock();
                defer stderr_mutex.unlock();
                writeStderr(line);
            }
            if (is_windows) {
                const win = struct {
                    pub extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;
                };
                win.Sleep(80);
            } else {
                std.posix.nanosleep(&.{ .sec = 0, .nsec = 80 * 1_000_000 }, null);
            }
            i += 1;
        }
        {
            stderr_mutex.lock();
            defer stderr_mutex.unlock();
            writeStderr("\r\x1b[2K");
        }
    }

    pub fn stop(self: *Spinner) void {
        self.active.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

/// Renders a modern Next.js / Astro style sharp rectangular status card.
pub fn renderBoxCard(writer: anytype, title: []const u8, lines: []const []const u8, width: usize) !void {
    const b = getBorder();
    const caps = capabilities.get();
    const cyan = if (caps.has_color) "\x1b[1;36m" else "";
    const reset = if (caps.has_color) "\x1b[0m" else "";
    const dim = if (caps.has_color) "\x1b[2;90m" else "";

    // Left margin 2 spaces
    try writer.writeAll("\n  ");

    // Top border with title
    try writer.writeAll(dim);
    try writer.writeAll(b.tl);
    try writer.writeAll(b.h);
    try writer.writeAll(b.h);
    try writer.writeAll(reset);
    try writer.print(" {s}{s}{s} ", .{ cyan, title, reset });
    
    const title_vis_len = visibleWidth(title) + 4;
    var rem: usize = if (width > title_vis_len) width - title_vis_len else 4;
    while (rem > 0) : (rem -= 1) {
        try writer.writeAll(dim);
        try writer.writeAll(b.h);
        try writer.writeAll(reset);
    }
    try writer.writeAll(dim);
    try writer.writeAll(b.tr);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Empty padding line
    try writer.writeAll("  ");
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    var pad: usize = 0;
    while (pad < width) : (pad += 1) try writer.writeAll(" ");
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Content lines
    for (lines) |line| {
        try writer.writeAll("  ");
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.writeAll("  ");
        try writer.writeAll(line);

        const vis_len = visibleWidth(line) + 2;
        if (width > vis_len) {
            var space_pad: usize = width - vis_len;
            while (space_pad > 0) : (space_pad -= 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.writeAll("\n");
    }

    // Empty padding line
    try writer.writeAll("  ");
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    pad = 0;
    while (pad < width) : (pad += 1) try writer.writeAll(" ");
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Bottom border
    try writer.writeAll("  ");
    try writer.writeAll(dim);
    try writer.writeAll(b.bl);
    var b_pad: usize = 0;
    while (b_pad < width) : (b_pad += 1) {
        try writer.writeAll(b.h);
    }
    try writer.writeAll(b.br);
    try writer.writeAll(reset);
    try writer.writeAll("\n\n");
}

/// Renders a Vite / Rust / Astro style diagnostic card for compiler errors.
pub fn renderErrorCard(
    writer: anytype,
    code: []const u8,
    msg: []const u8,
    file_path: []const u8,
    line_num: usize,
    col_num: usize,
    line_src: []const u8,
    hint: ?[]const u8,
    width: usize,
) !void {
    const b = getBorder();
    const caps = capabilities.get();
    const red = if (caps.has_color) "\x1b[1;31m" else "";
    const badge_red = if (caps.has_color) "\x1b[1;97;41m" else "";
    const cyan = if (caps.has_color) "\x1b[36m" else "";
    const yellow = if (caps.has_color) "\x1b[33m" else "";
    const dim = if (caps.has_color) "\x1b[2;90m" else "";
    const reset = if (caps.has_color) "\x1b[0m" else "";

    // Top border with badge
    try writer.writeAll(dim);
    try writer.writeAll(b.tl);
    try writer.writeAll(b.h);
    try writer.writeAll(reset);
    try writer.print(" {s} ✖ ERROR {s} ", .{ badge_red, reset });
    if (code.len > 0) {
        try writer.print("{s}[{s}]{s} ", .{ red, code, reset });
    }

    const title_vis = 14 + code.len;
    var rem: usize = if (width > title_vis) width - title_vis else 4;
    while (rem > 0) : (rem -= 1) {
        try writer.writeAll(dim);
        try writer.writeAll(b.h);
        try writer.writeAll(reset);
    }
    try writer.writeAll(dim);
    try writer.writeAll(b.tr);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Message line
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.print("  {s}{s}{s}", .{ red, msg, reset });
    const msg_vis = visibleWidth(msg) + 2;
    if (width > msg_vis) {
        var p: usize = width - msg_vis;
        while (p > 0) : (p -= 1) try writer.writeAll(" ");
    }
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Empty line
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    var p: usize = 0;
    while (p < width) : (p += 1) try writer.writeAll(" ");
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // File pointer line
    var fp_buf: [256]u8 = undefined;
    const fp_text = std.fmt.bufPrint(&fp_buf, "──> {s}:{d}:{d}", .{ file_path, line_num, col_num }) catch "──> file";
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.print("   {s}{s}{s}", .{ cyan, fp_text, reset });
    const fp_vis = visibleWidth(fp_text) + 3;
    if (width > fp_vis) {
        var s: usize = width - fp_vis;
        while (s > 0) : (s -= 1) try writer.writeAll(" ");
    }
    try writer.writeAll(dim);
    try writer.writeAll(b.v);
    try writer.writeAll(reset);
    try writer.writeAll("\n");

    // Code snippet line if available
    if (line_src.len > 0) {
        var code_buf: [512]u8 = undefined;
        const line_fmt = std.fmt.bufPrint(&code_buf, "{d: >4} │ {s}", .{ line_num, line_src }) catch "";
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.print("   {s}{s}{s}", .{ dim, line_fmt, reset });
        const line_vis = visibleWidth(line_fmt) + 3;
        if (width > line_vis) {
            var s: usize = width - line_vis;
            while (s > 0) : (s -= 1) try writer.writeAll(" ");
        }
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.writeAll("\n");

        // Pointer underline
        var arrow_buf: [256]u8 = undefined;
        var caret_idx: usize = 0;
        while (caret_idx < col_num and caret_idx + 7 < arrow_buf.len) : (caret_idx += 1) {
            arrow_buf[caret_idx] = ' ';
        }
        arrow_buf[caret_idx] = '^';
        arrow_buf[caret_idx + 1] = '-';
        arrow_buf[caret_idx + 2] = '-';
        arrow_buf[caret_idx + 3] = ' ';
        arrow_buf[caret_idx + 4] = 'h';
        arrow_buf[caret_idx + 5] = 'e';
        arrow_buf[caret_idx + 6] = 'r';
        arrow_buf[caret_idx + 7] = 'e';
        const arr_sub = arrow_buf[0 .. caret_idx + 8];

        var caret_fmt_buf: [512]u8 = undefined;
        const arr_fmt = std.fmt.bufPrint(&caret_fmt_buf, "     │ {s}", .{arr_sub}) catch "";
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.print("   {s}{s}{s}", .{ red, arr_fmt, reset });
        const arr_vis = visibleWidth(arr_fmt) + 3;
        if (width > arr_vis) {
            var s: usize = width - arr_vis;
            while (s > 0) : (s -= 1) try writer.writeAll(" ");
        }
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.writeAll("\n");
    }

    // Hint line if provided
    if (hint) |h| {
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.print("   {s}= hint: {s}{s}", .{ yellow, h, reset });
        const h_vis = visibleWidth(h) + 11;
        if (width > h_vis) {
            var s: usize = width - h_vis;
            while (s > 0) : (s -= 1) try writer.writeAll(" ");
        }
        try writer.writeAll(dim);
        try writer.writeAll(b.v);
        try writer.writeAll(reset);
        try writer.writeAll("\n");
    }

    // Bottom border
    try writer.writeAll(dim);
    try writer.writeAll(b.bl);
    var b_pad: usize = 0;
    while (b_pad < width) : (b_pad += 1) {
        try writer.writeAll(b.h);
    }
    try writer.writeAll(b.br);
    try writer.writeAll(reset);
    try writer.writeAll("\n");
}

pub fn renderErrorCardStderr(code: []const u8, message: []const u8, file: []const u8, line: usize, col: usize, snippet: []const u8, hint: ?[]const u8, width: usize) void {
    const w = DebugWriter{};
    renderErrorCard(w, code, message, file, line, col, snippet, hint, width) catch {};
}
