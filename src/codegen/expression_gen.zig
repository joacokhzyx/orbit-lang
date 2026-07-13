//! AST expression → C source text generator.
//!
//! `ExpressionGenerator` walks expression `Node`s produced by the parser and
//! writes the equivalent C source text into a shared `ArrayListUnmanaged(u8)`
//! output buffer.  It is used by `StatementGenerator` and `RouteGenerator`.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

/// Generates C source text for a single expression sub-tree.
pub const ExpressionGenerator = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    source: []const u8,

    /// Initialise an `ExpressionGenerator` that writes into `output`.
    /// `source` is the original Orbit source text used to extract token text.
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), source: []const u8) ExpressionGenerator {
        return .{
            .allocator = allocator,
            .output = output,
            .source = source,
        };
    }

    /// Recursively emit C source text for `node` into the output buffer.
    /// Dispatches on the node tag and handles all expression kinds.
    pub fn generate(self: *ExpressionGenerator, node: *Node) anyerror!void {
        switch (node.tag) {
            .integer_literal => try self.output.appendSlice(self.allocator, node.data.integer_literal.getText(self.source)),
            .char_literal => {
                const code = node.data.char_literal.charCode(self.source);
                const text = try std.fmt.allocPrint(self.allocator, "{d}", .{code});
                try self.output.appendSlice(self.allocator, text);
            },
            .float_literal => try self.output.appendSlice(self.allocator, node.data.float_literal.getText(self.source)),
            .string_literal => {
                try self.output.append(self.allocator, '"');
                try self.output.appendSlice(self.allocator, node.data.string_literal.getText(self.source));
                try self.output.append(self.allocator, '"');
            },
            .boolean_literal => {
                const text = node.data.boolean_literal.getText(self.source);
                if (std.mem.eql(u8, text, "true")) {
                    try self.output.appendSlice(self.allocator, "true");
                } else {
                    try self.output.appendSlice(self.allocator, "false");
                }
            },
            .identifier => try self.output.appendSlice(self.allocator, node.data.identifier.getText(self.source)),
            .binary_op => try self.generateBinaryOp(node),
            .call => try self.generateCall(node),
            .member_access => try self.generateMemberAccess(node),
            .array_literal => try self.generateArrayLiteral(node),
            .object_literal => try self.generateObjectLiteral(node),
            else => {},
        }
    }

    fn generateBinaryOp(self: *ExpressionGenerator, node: *Node) anyerror!void {
        const bin_data = node.data.binary_op;

        try self.output.append(self.allocator, '(');
        try self.generate(bin_data.lhs);
        try self.output.append(self.allocator, ' ');

        const op_text = bin_data.op.getText(self.source);
        if (std.mem.eql(u8, op_text, "==")) {
            try self.output.appendSlice(self.allocator, "==");
        } else if (std.mem.eql(u8, op_text, "!=")) {
            try self.output.appendSlice(self.allocator, "!=");
        } else if (std.mem.eql(u8, op_text, "&&")) {
            try self.output.appendSlice(self.allocator, "&&");
        } else if (std.mem.eql(u8, op_text, "||")) {
            try self.output.appendSlice(self.allocator, "||");
        } else {
            try self.output.appendSlice(self.allocator, op_text);
        }

        try self.output.append(self.allocator, ' ');
        try self.generate(bin_data.rhs);
        try self.output.append(self.allocator, ')');
    }

    fn generateCall(self: *ExpressionGenerator, node: *Node) anyerror!void {
        const call_data = node.data.call;

        if (call_data.func.tag == .identifier) {
            const func_name = call_data.func.data.identifier.getText(self.source);
            try self.output.appendSlice(self.allocator, func_name);
        } else if (call_data.func.tag == .member_access) {
            try self.generateMemberAccess(call_data.func);
        }

        try self.output.append(self.allocator, '(');

        for (call_data.args, 0..) |arg, i| {
            if (i > 0) try self.output.appendSlice(self.allocator, ", ");
            try self.generate(arg);
        }

        try self.output.append(self.allocator, ')');
    }

    fn generateMemberAccess(self: *ExpressionGenerator, node: *Node) anyerror!void {
        const member_data = node.data.member_access;
        try self.generate(member_data.object);
        try self.output.append(self.allocator, '.');
        try self.output.appendSlice(self.allocator, member_data.member.getText(self.source));
    }

    fn generateArrayLiteral(self: *ExpressionGenerator, node: *Node) anyerror!void {
        try self.output.append(self.allocator, '{');

        for (node.data.array_literal.elements, 0..) |elem, i| {
            if (i > 0) try self.output.appendSlice(self.allocator, ", ");
            try self.generate(elem);
        }

        try self.output.append(self.allocator, '}');
    }

    fn generateObjectLiteral(self: *ExpressionGenerator, node: *Node) anyerror!void {
        try self.output.appendSlice(self.allocator, "{");

        for (node.data.object_literal.fields, 0..) |field, i| {
            if (i > 0) try self.output.appendSlice(self.allocator, ", ");
            try self.output.append(self.allocator, '.');
            try self.output.appendSlice(self.allocator, field.data.field_init.name.getText(self.source));
            try self.output.appendSlice(self.allocator, " = ");
            try self.generate(field.data.field_init.value);
        }

        try self.output.append(self.allocator, '}');
    }
};
