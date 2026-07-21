const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IROpcode = ir.IROpcode;
const cost_model = @import("cost_model.zig");
const pattern_matcher = @import("pattern_matcher.zig");
const synthesis = @import("synthesis.zig");

pub const BenchmarkResult = struct {
    total_instructions: usize,
    total_cost_before: f64,
    total_cost_after: f64,
    pattern_hits: usize,
    synthesis_hits: usize,
    dual_path_functions: usize,
    superopt_improvements: usize,
};

pub fn evaluate(instructions: []const IRInstruction) BenchmarkResult {
    var result = BenchmarkResult{
        .total_instructions = instructions.len,
        .total_cost_before = 0,
        .total_cost_after = 0,
        .pattern_hits = 0,
        .synthesis_hits = 0,
        .dual_path_functions = 0,
        .superopt_improvements = 0,
    };

    var i: usize = 0;
    while (i < instructions.len) {
        const cost_before = cost_model.evaluateSlice(instructions[i..@min(i + 10, instructions.len)]);

        if (synthesis.findSynthesis(instructions, i)) |m| {
            result.synthesis_hits += 1;
            const rule = synthesis.getRuleInfo(m.rule_index);
            const cost_after = cost_before.total() / rule.cost_reduction;
            result.total_cost_before += cost_before.total();
            result.total_cost_after += cost_after;
            i += m.length;
        } else if (pattern_matcher.findBest(instructions, i)) |m| {
            result.pattern_hits += 1;
            result.total_cost_before += m.cost_before.total();
            result.total_cost_after += m.cost_after.total();
            i += m.length;
        } else {
            result.total_cost_before += cost_before.total();
            result.total_cost_after += cost_before.total();
            i += 1;
        }
    }

    return result;
}

pub fn printSummary(writer: anytype, result: BenchmarkResult) !void {
    const speedup = if (result.total_cost_after > 0)
        result.total_cost_before / result.total_cost_after
    else
        1.0;

    try writer.print("\n=== Superluminal Benchmark ===\n", .{});
    try writer.print("  Instructions:    {d:>8}\n", .{result.total_instructions});
    try writer.print("  Cost (before):   {d:>8.1}\n", .{result.total_cost_before});
    try writer.print("  Cost (after):    {d:>8.1}\n", .{result.total_cost_after});
    try writer.print("  Speedup:         {d:>8.2}x\n", .{speedup});
    try writer.print("  Pattern hits:    {d:>8}\n", .{result.pattern_hits});
    try writer.print("  Synthesis hits:  {d:>8}\n", .{result.synthesis_hits});
    try writer.print("===============================\n\n", .{});
}
