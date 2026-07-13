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
