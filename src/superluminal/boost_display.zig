const std = @import("std");

pub const BoostMetrics = struct {
    total_instructions: usize = 0,
    total_cost_before: f64 = 0,
    total_cost_after: f64 = 0,
    synthesis_hits: usize = 0,
    pattern_hits: usize = 0,
    superopt_improvements: usize = 0,
    branch_opt_savings: f64 = 0,
    mem_opt_savings: f64 = 0,

    pub fn boostPercent(self: BoostMetrics) f64 {
        if (self.total_cost_after >= self.total_cost_before) return 0;
        return (1.0 - self.total_cost_after / self.total_cost_before) * 100.0;
    }
};

fn lerp(a: u8, b: u8, t: f64) u8 {
    return @intFromFloat(@as(f64, @floatFromInt(a)) + (@as(f64, @floatFromInt(b)) - @as(f64, @floatFromInt(a))) * t);
}

/// Formats "Superluminal boosted X.X%" with a pink→rose gradient into buf.
/// Returns the written slice, or a plain ASCII fallback if the buffer is too small.
pub fn formatBoostLine(buf: []u8, pct: f64) []const u8 {
    var plain_buf: [64]u8 = undefined;
    const plain = std.fmt.bufPrint(&plain_buf, "Superluminal boosted {d:.1}%", .{pct}) catch return "";

    const start_r: u8 = 255;
    const start_g: u8 = 105;
    const start_b: u8 = 180; // hot pink
    const end_r: u8 = 255;
    const end_g: u8 = 228;
    const end_b: u8 = 225; // rose white

    const n = plain.len;
    var pos: usize = 0;

    for (plain, 0..) |ch, i| {
        const t: f64 = if (n > 1) @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1)) else 0.0;
        const r = lerp(start_r, end_r, t);
        const g = lerp(start_g, end_g, t);
        const b = lerp(start_b, end_b, t);
        const chunk = std.fmt.bufPrint(buf[pos..], "\x1b[38;2;{d};{d};{d}m{c}", .{ r, g, b, ch }) catch return plain;
        pos += chunk.len;
    }

    const reset = "\x1b[0m";
    if (pos + reset.len <= buf.len) {
        @memcpy(buf[pos .. pos + reset.len], reset);
        pos += reset.len;
    }

    return buf[0..pos];
}

/// No-op: the standalone Superluminal box has been replaced by a single
/// gradient line inside the "Orbit build complete" box.
pub fn printBoost(_: BoostMetrics) void {}
