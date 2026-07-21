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

fn gradientText(text: []const u8) void {
    const start_r: u8 = 255;
    const start_g: u8 = 105;
    const start_b: u8 = 180;
    const end_r: u8 = 255;
    const end_g: u8 = 228;
    const end_b: u8 = 225;
    const steps = text.len;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const t = if (steps > 1) @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps - 1)) else 0.0;
        const r = lerp(start_r, end_r, t);
        const g = lerp(start_g, end_g, t);
        const b = lerp(start_b, end_b, t);
        std.debug.print("\x1b[38;2;{d};{d};{d}m{c}\x1b[0m", .{ r, g, b, text[i] });
    }
}

pub fn printBoost(metrics: BoostMetrics) void {
    const pct = metrics.boostPercent();
    if (pct < 0.5) return;

    const pct_str = std.fmt.allocPrint(std.heap.page_allocator, "{d:.1}", .{pct}) catch return;
    defer std.heap.page_allocator.free(pct_str);

    std.debug.print("\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m╔══════════════════════════════════════╗\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m  \x1b[1m\x1b[38;2;255;182;193m⚡ Superluminal\x1b[0m  ", .{});
    gradientText(pct_str);
    std.debug.print("%  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m  \x1b[2m", .{});
    std.debug.print("  Boosted  ", .{});
    std.debug.print("         \x1b[0m  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m  \x1b[2m", .{});
    std.debug.print("  Synthesis hits:  {d}", .{metrics.synthesis_hits});
    std.debug.print("         \x1b[0m  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m  \x1b[2m", .{});
    std.debug.print("  Pattern hits:    {d}", .{metrics.pattern_hits});
    std.debug.print("         \x1b[0m  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m  \x1b[2m", .{});
    std.debug.print("  Cost reduction:  {d:.0} to {d:.0}", .{ metrics.total_cost_before, metrics.total_cost_after });
    std.debug.print("   \x1b[0m  \x1b[1m\x1b[38;2;255;105;180m║\x1b[0m\n", .{});
    std.debug.print("  \x1b[1m\x1b[38;2;255;105;180m╚══════════════════════════════════════╝\x1b[0m\n", .{});
    std.debug.print("\n", .{});
}
