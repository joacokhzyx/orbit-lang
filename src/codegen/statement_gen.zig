const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;
const ExpressionGenerator = @import("expression_gen.zig").ExpressionGenerator;

pub const StatementGenerator = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    source: []const u8,
    indent_level: u32,
    
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), source: []const u8) StatementGenerator {
        return .{
            .allocator = allocator,
            .output = output,
            .source = source,
            .indent_level = 0,
        };
    }
    
    pub fn generate(self: *StatementGenerator, node: *Node) anyerror!void {
        switch (node.tag) {
            .block => try self.generateBlock(node),
            .expression_stmt => try self.generateExpressionStmt(node),
            .return_stmt => try self.generateReturnStmt(node),
            .val_decl => try self.generateValDecl(node),
            .if_stmt => try self.generateIfStmt(node),
            .for_stmt => try self.generateForStmt(node),
            .while_stmt => try self.generateWhileStmt(node),
            else => {},
        }
    }
    
    fn writeIndent(self: *StatementGenerator) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.output.appendSlice(self.allocator, "    ");
        }
    }
    
    fn generateBlock(self: *StatementGenerator, node: *Node) !void {
        try self.output.appendSlice(self.allocator, "{\n");
        self.indent_level += 1;
        for (node.data.block.stmts) |stmt| {
            try self.generate(stmt);
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "}\n");
    }
    
    fn generateExpressionStmt(self: *StatementGenerator, node: *Node) !void {
        try self.writeIndent();
        var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
        try expr_gen.generate(node.data.expression_stmt.expr);
        try self.output.appendSlice(self.allocator, ";\n");
    }
    
    fn generateReturnStmt(self: *StatementGenerator, node: *Node) !void {
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "return ");
        
        if (node.data.return_stmt.expr) |expr| {
            var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
            try expr_gen.generate(expr);
        }
        
        try self.output.appendSlice(self.allocator, ";\n");
    }
    
    fn generateValDecl(self: *StatementGenerator, node: *Node) !void {
        const val_data = node.data.val_decl;
        
        try self.writeIndent();
        
        if (val_data.type_annotation) |type_ann| {
            // Fix: access token from type_annotation node
            const type_name = type_ann.data.type_annotation.base.getText(self.source);
            try self.output.appendSlice(self.allocator, self.mapOrbitTypeToC(type_name));
        } else {
            try self.output.appendSlice(self.allocator, "orbit_string");
        }
        
        try self.output.append(self.allocator, ' ');
        try self.output.appendSlice(self.allocator, val_data.name.getText(self.source));
        
        if (val_data.value) |value| {
            try self.output.appendSlice(self.allocator, " = ");
            var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
            try expr_gen.generate(value);
        }
        
        try self.output.appendSlice(self.allocator, ";\n");
    }
    
    fn generateIfStmt(self: *StatementGenerator, node: *Node) !void {
        const if_data = node.data.if_stmt;
        
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "if (");
        
        var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
        try expr_gen.generate(if_data.condition);
        
        try self.output.appendSlice(self.allocator, ") ");
        
        try self.generate(if_data.then_branch);
        
        if (if_data.else_branch) |else_branch| {
            try self.writeIndent();
            try self.output.appendSlice(self.allocator, "else ");
            try self.generate(else_branch);
        }
    }
    
    fn generateForStmt(self: *StatementGenerator, node: *Node) !void {
        const for_data = node.data.for_stmt;
        const item_name = for_data.item.getText(self.source);
        
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "for (int ");
        try self.output.appendSlice(self.allocator, item_name);
        try self.output.appendSlice(self.allocator, " = 0; ");
        try self.output.appendSlice(self.allocator, item_name);
        try self.output.appendSlice(self.allocator, " < ");
        
        var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
        try expr_gen.generate(for_data.iterable);
        
        try self.output.appendSlice(self.allocator, "; ");
        try self.output.appendSlice(self.allocator, item_name);
        try self.output.appendSlice(self.allocator, "++) ");
        
        try self.generate(for_data.body);
    }
    
    fn generateWhileStmt(self: *StatementGenerator, node: *Node) !void {
        const while_data = node.data.while_stmt;
        
        try self.writeIndent();
        try self.output.appendSlice(self.allocator, "while (");
        
        var expr_gen = ExpressionGenerator.init(self.allocator, self.output, self.source);
        try expr_gen.generate(while_data.condition);
        
        try self.output.appendSlice(self.allocator, ") ");
        
        try self.generate(while_data.body);
    }
    
    fn mapOrbitTypeToC(self: *StatementGenerator, orbit_type: []const u8) []const u8 {
        _ = self;
        if (std.mem.eql(u8, orbit_type, "int")) return "orbit_int";
        if (std.mem.eql(u8, orbit_type, "float")) return "orbit_float";
        if (std.mem.eql(u8, orbit_type, "string")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "bool")) return "orbit_bool";
        return "orbit_string";
    }
};
