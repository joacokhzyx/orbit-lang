//! Terminal symbol catalogue for the Orbit compiler output layer.
//! Maps semantic symbol names (orbit logo, success/error indicators, tree
//! connectors …) to their Unicode or ASCII fallback strings, based on the
//! globally detected terminal capabilities.

const std = @import("std");
const capabilities = @import("capabilities.zig");

/// Named symbols used by Orbit's terminal output helpers.
pub const Symbol = enum {
    /// The Orbit logo glyph (`⏣` or `*`).
    orbit,
    /// Success indicator (`✓` or `OK`).
    success,
    /// Error indicator (`×` or `X`).
    err,
    /// Warning indicator (always `!`).
    warning,
    /// Right-arrow (`→` or `->`).
    arrow,
    /// Tree node bullet (`●` or `o`).
    node,
    /// Tree branch connector (`├─` or `+-`).
    branch,
    /// Last tree branch connector (`└─` or `\-`).
    last_branch,
};

/// Returns the string representation of `sym` for the current terminal.
/// Uses Unicode characters when `has_unicode` is `true`; falls back to
/// plain ASCII otherwise.
pub fn get(sym: Symbol) []const u8 {
    const caps = capabilities.get();
    const unicode = caps.has_unicode;

    switch (sym) {
        .orbit => return if (unicode) "⏣" else "*",
        .success => return if (unicode) "✓" else "OK",
        .err => return if (unicode) "×" else "X",
        .warning => return "!",
        .arrow => return if (unicode) "→" else "->",
        .node => return if (unicode) "●" else "o",
        .branch => return if (unicode) "├─" else "+-",
        .last_branch => return if (unicode) "└─" else "\\-",
    }
}
