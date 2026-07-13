const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const Symbol = enum {
    orbit,
    success,
    err,
    warning,
    arrow,
    node,
    branch,
    last_branch,
};

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
