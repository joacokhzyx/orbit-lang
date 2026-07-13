const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const Style = enum {
    primary,
    accent,
    success,
    warning,
    err,
    muted,
    label,
    value,
    code,
};

pub fn getEsc(style: Style) []const u8 {
    const caps = capabilities.get();
    if (!caps.has_color) return "";
    
    switch (style) {
        .primary => return "\x1b[36m", // Cyan
        .accent => return "\x1b[35m", // Magenta
        .success => return "\x1b[32m", // Green
        .warning => return "\x1b[33m", // Yellow
        .err => return "\x1b[31m", // Red
        .muted => return "\x1b[90m", // Gray
        .label => return "\x1b[1;37m", // Bold White
        .value => return "\x1b[37m", // White
        .code => return "\x1b[36m", // Cyan
    }
}

pub fn getReset() []const u8 {
    const caps = capabilities.get();
    if (!caps.has_color) return "";
    return "\x1b[0m";
}

pub fn format(style: Style, text: []const u8, buf: []u8) ![]const u8 {
    const esc = getEsc(style);
    const reset = getReset();
    if (esc.len == 0) {
        if (buf.len < text.len) return error.NoSpaceLeft;
        std.mem.copyForwards(u8, buf[0..text.len], text);
        return buf[0..text.len];
    }
    const needed = esc.len + text.len + reset.len;
    if (buf.len < needed) return error.NoSpaceLeft;
    std.mem.copyForwards(u8, buf[0..esc.len], esc);
    std.mem.copyForwards(u8, buf[esc.len .. esc.len + text.len], text);
    std.mem.copyForwards(u8, buf[esc.len + text.len .. needed], reset);
    return buf[0..needed];
}
