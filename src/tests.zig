const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const ir_opt = @import("ir/optimizer.zig");

// Test suite for IR call instruction parameter passing
test "ir.call_instruction_parameters" {
    // Test basic call with no parameters
    var instr1 = @import("../ir/ir.zig").IRInstruction.call(1, "func1", &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instr1.opcode);
    try std.testing.expectEqual(@as(?u32, 1), instr1.dest);
    try std.testing.expectEqualStrings("func1", instr1.operand1.string);
    try std.testing.expectEqual(@as(u32, 0), instr1.operand2.register);

    // Test call with parameters
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 42 },
        @import("../ir/ir.zig").IRValue{ .string = "hello" },
        @import("../ir/ir.zig").IRValue{ .bool = true },
    };
    var instr2 = @import("../ir/ir.zig").IRInstruction.call(2, "func2", params);
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instr2.opcode);
    try std.testing.expectEqual(@as(?u32, 2), instr2.dest);
    try std.testing.expectEqualStrings("func2", instr2.operand1.string);
    try std.testing.expectEqual(@as(u32, 3), instr2.operand2.register);
}

test "ir.call_instruction_parameter_count" {
    // Test parameter count is correctly stored
    const params1 = &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .int = 1 } };
    var instr1 = @import("../ir/ir.zig").IRInstruction.call(1, "single", params1);
    try std.testing.expectEqual(@as(u32, 1), instr1.operand2.register);

    const params2 = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 1 },
        @import("../ir/ir.zig").IRValue{ .int = 2 },
        @import("../ir/ir.zig").IRValue{ .int = 3 },
        @import("../ir/ir.zig").IRValue{ .int = 4 },
    };
    var instr2 = @import("../ir/ir.zig").IRInstruction.call(2, "quad", params2);
    try std.testing.expectEqual(@as(u32, 4), instr2.operand2.register);
}

test "ir.call_instruction_dest_register" {
    // Test destination register is correctly set
    var instr1 = @import("../ir/ir.zig").IRInstruction.call(5, "func", &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqual(@as(?u32, 5), instr1.dest);

    var instr2 = @import("../ir/ir.zig").IRInstruction.call(10, "another", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .int = 100 } });
    try std.testing.expectEqual(@as(?u32, 10), instr2.dest);
}

test "ir.call_instruction_function_name" {
    // Test function name is correctly stored
    var instr1 = @import("../ir/ir.zig").IRInstruction.call(1, "my_function", &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqualStrings("my_function", instr1.operand1.string);

    var instr2 = @import("../ir/ir.zig").IRInstruction.call(2, "another_func", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .float = 3.14 } });
    try std.testing.expectEqualStrings("another_func", instr2.operand1.string);
}

test "ir.call_instruction_empty_parameters" {
    // Test empty parameter list
    var instr = @import("../ir/ir.zig").IRInstruction.call(1, "empty", &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqual(@as(u32, 0), instr.operand2.register);
    try std.testing.expectEqual(@as(u32, 0), instr.operand3.register);
}

test "ir.call_instruction_parameter_storage" {
    // Test that parameters are accessible via operand3
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 42 },
        @import("../ir/ir.zig").IRValue{ .string = "test" },
    };
    var instr = @import("../ir/ir.zig").IRInstruction.call(1, "store", params);

    // In actual implementation, parameters would be stored in a separate structure
    // This test verifies the instruction structure is correctly formed
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instr.opcode);
    try std.testing.expectEqual(@as(?u32, 1), instr.dest);
    try std.testing.expectEqualStrings("store", instr.operand1.string);
    try std.testing.expectEqual(@as(u32, 2), instr.operand2.register);
}

// Performance test for parameter passing
const std = @import("std");
const testing = std.testing;

const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;

const allocator = std.testing.allocator;

test "ir.call_instruction_performance" {
    // Test parameter passing with various sizes
    const test_cases = &[_][]const u8{
        "empty",
        "single",
        "double",
        "triple",
        "many_parameters_function_name_that_is_very_long",
    };

    for (test_cases) |func_name| {
        // Test with 0 parameters
        var instr0 = @import("../ir/ir.zig").IRInstruction.call(1, func_name, &[_]@import("../ir/ir.zig").IRValue{});
        try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instr0.opcode);
        try std.testing.expectEqualStrings(func_name, instr0.operand1.string);

        // Test with 1 parameter
        var instr1 = @import("../ir/ir.zig").IRInstruction.call(2, func_name, &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .int = 100 } });
        try std.testing.expectEqual(@as(u32, 1), instr1.operand2.register);

        // Test with 5 parameters
        var instr5 = @import("../ir/ir.zig").IRInstruction.call(3, func_name, &[_]@import("../ir/ir.zig").IRValue{
            @import("../ir/ir.zig").IRValue{ .int = 1 },
            @import("../ir/ir.zig").IRValue{ .int = 2 },
            @import("../ir/ir.zig").IRValue{ .int = 3 },
            @import("../ir/ir.zig").IRValue{ .int = 4 },
            @import("../ir/ir.zig").IRValue{ .int = 5 },
        });
        try std.testing.expectEqual(@as(u32, 5), instr5.operand2.register);
    }
}

test "ir.call_instruction_large_function_name" {
    // Test with very long function names
    const long_name = &[_]u8{0} ** 1000; // 1000 character function name
    for (0..1000) |i| {
        long_name[i] = @intCast(u8, 'a' + (i % 26));
    }
    const long_name_str = std.mem.sliceTo(&long_name, 0);

    var instr = @import("../ir/ir.zig").IRInstruction.call(1, long_name_str, &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqualStrings(long_name_str, instr.operand1.string);
}

test "ir.call_instruction_multiple_calls" {
    // Test creating multiple call instructions
    var instrs = std.ArrayList(@import("../ir/ir.zig").IRInstruction).init(allocator);
    defer instrs.deinit();

    try instrs.append(@import("../ir/ir.zig").IRInstruction.call(1, "func1", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .int = 1 } }));
    try instrs.append(@import("../ir/ir.zig").IRInstruction.call(2, "func2", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .string = "hello" } }));
    try instrs.append(@import("../ir/ir.zig").IRInstruction.call(3, "func3", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .bool = true } }));

    try std.testing.expectEqual(@as(usize, 3), instrs.items.len);
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instrs.items[0].opcode);
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instrs.items[1].opcode);
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instrs.items[2].opcode);
}

test "ir.call_instruction_different_parameter_types" {
    // Test with different parameter types
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 42 },
        @import("../ir/ir.zig").IRValue{ .float = 3.14 },
        @import("../ir/ir.zig").IRValue{ .string = "hello" },
        @import("../ir/ir.zig").IRValue{ .bool = true },
        @import("../ir/ir.zig").IRValue{ .none = {} },
    };

    var instr = @import("../ir/ir.zig").IRInstruction.call(1, "mixed", params);
    try std.testing.expectEqual(@as(u32, 5), instr.operand2.register);

    // Verify instruction structure is valid
    try std.testing.expectEqual(@import("../ir/ir.zig").IROpcode.call, instr.opcode);
    try std.testing.expectEqual(@as(?u32, 1), instr.dest);
    try std.testing.expectEqualStrings("mixed", instr.operand1.string);
}

// Test IRBuilder call instruction generation
const ir_builder = @import("../ir/builder.zig");
const IRBuilder = ir_builder.IRBuilder;

const ast = @import("../ast.zig");
const Node = ast.Node;

const lexer = @import("../lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenType = lexer.TokenType;

const parser = @import("../parser.zig");
const Parser = parser.Parser;

test "ir_builder_call_instruction" {
    // Create a simple AST with a function call
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test source code
    const source = \n"""
func add(a: int, b: int) -> int {
    return a + b
}

val result = add(5, 3)
""";

    // Lex the source
    var lexer = Lexer.init(source, allocator);
    var current_token = lexer.next();
    var previous_token = lexer.next();

    // Parse the source
    var parser = Parser.init(source, allocator);
    const root = parser.parse() catch unreachable;

    // Create IRBuilder
    var ir_builder = IRBuilder.init(allocator, source, &std.AutoHashMapUnmanaged(*Node, []const u8){}.init(allocator));
    defer ir_builder.deinit();

    // Build the AST into IR
    const ir_module = ir_builder.build(root) catch unreachable;
    defer ir_module.deinit();

    // Verify the call instruction was generated correctly
    // (This would require examining the IRModule structure)
    // For now, we just verify the build completed successfully
    try std.testing.expect(ir_module.functions.items.len > 0);
}

test "ir_builder_call_with_parameters" {
    // Create AST with function call that has parameters
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source = \n"""
func multiply(x: int, y: int) -> int {
    return x * y
}

val product = multiply(10, 20)
""";

    var lexer = Lexer.init(source, allocator);
    var current_token = lexer.next();
    var previous_token = lexer.next();

    var parser = Parser.init(source, allocator);
    const root = parser.parse() catch unreachable;

    var ir_builder = IRBuilder.init(allocator, source, &std.AutoHashMapUnmanaged(*Node, []const u8){}.init(allocator));
    defer ir_builder.deinit();

    const ir_module = ir_builder.build(root) catch unreachable;
    defer ir_module.deinit();

    // Verify parameters were passed correctly
    // This would require more detailed IR inspection
    try std.testing.expect(ir_module.functions.items.len > 0);
}

// Test IRValue parameter passing
test "ir_value_parameter_types" {
    // Test various IRValue types as parameters
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 42 },
        @import("../ir/ir.zig").IRValue{ .float = 3.14 },
        @import("../ir/ir.zig").IRValue{ .string = "hello" },
        @import("../ir/ir.zig").IRValue{ .bool = true },
        @import("../ir/ir.zig").IRValue{ .none = {} },
    };

    var instr = @import("../ir/ir.zig").IRInstruction.call(1, "test", params);
    try std.testing.expectEqual(@as(u32, 5), instr.operand2.register);

    // Test with empty parameters
    var instr_empty = @import("../ir/ir.zig").IRInstruction.call(2, "empty", &[_]@import("../ir/ir.zig").IRValue{});
    try std.testing.expectEqual(@as(u32, 0), instr_empty.operand2.register);
}

test "ir_value_parameter_register_references" {
    // Test parameters that reference registers
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .register = 1 },
        @import("../ir/ir.zig").IRValue{ .register = 2 },
        @import("../ir/ir.zig").IRValue{ .register = 3 },
    };

    var instr = @import("../ir/ir.zig").IRInstruction.call(4, "registers", params);
    try std.testing.expectEqual(@as(u32, 3), instr.operand2.register);

    // Test single register parameter
    var instr_single = @import("../ir/ir.zig").IRInstruction.call(5, "single_reg", &[_]@import("../ir/ir.zig").IRValue{ @import("../ir/ir.zig").IRValue{ .register = 10 } });
    try std.testing.expectEqual(@as(u32, 1), instr_single.operand2.register);
}

test "ir_value_parameter_const_values" {
    // Test parameters with constant values
    const params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 100 },
        @import("../ir/ir.zig").IRValue{ .float = 2.718 },
        @import("../ir/ir.zig").IRValue{ .string = "const" },
        @import("../ir/ir.zig").IRValue{ .bool = false },
    };

    var instr = @import("../ir/ir.zig").IRInstruction.call(1, "constants", params);
    try std.testing.expectEqual(@as(u32, 4), instr.operand2.register);

    // Test mixed constant and register parameters
    const mixed_params = &[_]@import("../ir/ir.zig").IRValue{
        @import("../ir/ir.zig").IRValue{ .int = 50 },
        @import("../ir/ir.zig").IRValue{ .register = 1 },
        @import("../ir/ir.zig").IRValue{ .string = "mix" },
    };
    var instr_mixed = @import("../ir/ir.zig").IRInstruction.call(2, "mixed", mixed_params);
    try std.testing.expectEqual(@as(u32, 3), instr_mixed.operand2.register);
}

// Integration test for complete call instruction flow
test "ir_call_instruction_integration" {
    // Test complete flow from AST to IR instruction
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create source with multiple function calls
    const source = \n"""
func add(a: int, b: int) -> int {
    return a + b
}

func multiply(x: int, y: int) -> int {
    return x * y
}

val result1 = add(5, 3)
val result2 = multiply(result1, 2)
val result3 = add(result2, 10)
""";

    var lexer = Lexer.init(source, allocator);
    var current_token = lexer.next();
    var previous_token = lexer.next();

    var parser = Parser.init(source, allocator);
    const root = parser.parse() catch unreachable;

    var ir_builder = IRBuilder.init(allocator, source, &std.AutoHashMapUnmanaged(*Node, []const u8){}.init(allocator));
    defer ir_builder.deinit();

    const ir_module = ir_builder.build(root) catch unreachable;
    defer ir_module.deinit();

    // Verify multiple functions and call instructions were created
    try std.testing.expect(ir_module.functions.items.len >= 3); // main + add + multiply

    // Verify each function has expected instructions
    for (ir_module.functions.items) |func| {
        // Each function should have at least one instruction
        try std.testing.expect(func.instructions.items.len > 0);

        // Check for call instructions
        for (func.instructions.items) |instr| {
            if (instr.opcode == .call) {
                // Call instruction should have valid structure
                try std.testing.expect(instr.operand1 != .none);
                try std.testing.expect(instr.operand2 != .none);
            }
        }
    }
}

// Performance benchmark for parameter passing
test "ir_call_instruction_performance_benchmark" {
    const std = @import("std");
    const testing = std.testing;

    const benchmark = testing.benchmark;

    // Benchmark creating call instructions with various parameter counts
    const param_counts = &[_]usize{ 0, 1, 5, 10, 20 };

    for (param_counts) |count| {
        const params = try allocator.alloc(@import("../ir/ir.zig").IRValue, count);
        defer allocator.free(params);

        for (params) |*param, i| {
            param.* = switch (i % 4) {
                0 > @import("../ir/ir.zig").IRValue{ .int = @intCast(i64, i) },
                1 > @import("../ir/ir.zig").IRValue{ .float = @intToFloat(f64, i) },
                2 > @import("../ir/ir.zig").IRValue{ .string = "param" },
                3 > @import("../ir/ir.zig").IRValue{ .bool = i % 2 == 0 },
                else > @import("../ir/ir.zig").IRValue{ .none = {} },
            };
        }

        _ = benchmark("create_call_instruction_" ++ std.fmt.comptimePrint("{}", .{count}), {}, {
            var instr = @import("../ir/ir.zig").IRInstruction.call(1, "benchmark_func", params);
            _ = instr;
        });
    }
}