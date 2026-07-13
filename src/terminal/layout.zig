const std = @import("std");
const capabilities = @import("capabilities.zig");

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

pub const Border = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    v: []const u8,
};

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

pub fn horizontalRule(writer: anytype, width: usize) !void {
    const b = getBorder();
    var i: usize = 0;
    while (i < width) : (i += 1) {
        try writer.writeAll(b.h);
    }
}

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
