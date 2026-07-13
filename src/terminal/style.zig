//! ANSI colour-style helpers for the Orbit compiler output layer.
//! Maps semantic style names (`primary`, `success`, `err`, …) to ANSI
//! escape sequences, respecting the globally detected terminal capabilities.
//! When the terminal does not support colour, all helpers return empty strings
//! so that callers need not check capabilities themselves.

const std = @import("std");
const capabilities = @import("capabilities.zig");

/// Semantic colour/style identifiers used throughout the Orbit output layer.
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

/// Returns the ANSI opening escape sequence for `style`, or an empty string
/// when the terminal does not support colour.
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

/// Returns the ANSI reset sequence `\x1b[0m`, or an empty string when the
/// terminal does not support colour.
pub fn getReset() []const u8 {
    const caps = capabilities.get();
    if (!caps.has_color) return "";
    return "\x1b[0m";
}

/// Formats `text` with the ANSI escape sequence for `style` into `buf`.
///
/// When colour is disabled the raw text is copied into `buf` unchanged.
/// Returns a sub-slice of `buf` containing the formatted result.
/// Returns `error.NoSpaceLeft` when `buf` is too small.
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
