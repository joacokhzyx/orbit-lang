const std = @import("std");
const token = @import("../token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ast = @import("../ast.zig");
const Node = ast.Node;
const Lexer = @import("../lexer.zig").Lexer;
const ExpressionParser = @import("expression_parser.zig").ExpressionParser;

pub const StatementParser = struct {
    lexer: *Lexer,
    current_token: *Token,
    previous_token: *Token,
    allocator: std.mem.Allocator,
    source: []const u8,
    node_pool: std.ArrayListUnmanaged(*Node),

    pub fn init(lexer: *Lexer, current_token: *Token, previous_token: *Token, allocator: std.mem.Allocator, source: []const u8) StatementParser {
        return .{
            .lexer = lexer,
            .current_token = current_token,
            .previous_token = previous_token,
            .allocator = allocator,
            .source = source,
            .node_pool = .{},
        };
    }

    fn createNode(self: *StatementParser, tag: ast.Node.Tag, data: ast.Node.Data) !*Node {
        const node = try self.allocator.create(Node);
        try self.node_pool.append(self.allocator, node);
        node.* = .{
            .tag = tag,
            .data = data,
        };
        return node;
    }

    pub fn deinit(self: *StatementParser) void {
        for (self.node_pool.items) |node| {
            self.allocator.destroy(node);
        }
        self.node_pool.deinit(self.allocator);
    }
    
    fn advance(self: *StatementParser) void {
        self.previous_token.* = self.current_token.*;
        self.current_token.* = self.lexer.next();
    }
    
    fn check(self: *StatementParser, tag: TokenType) bool {
        return self.current_token.tag == tag;
    }
    
    fn match(self: *StatementParser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }
    
    fn consume(self: *StatementParser, tag: TokenType) !Token {
        if (self.current_token.tag == tag) {
            const tok = self.current_token.*;
            self.advance();
            return tok;
        }
        return error.UnexpectedToken;
    }
    
    pub fn parseStatement(self: *StatementParser) anyerror!*Node {
        if (self.check(.KeywordIf)) return try self.parseIf();
        if (self.check(.KeywordFor)) return try self.parseFor();
        if (self.check(.KeywordWhile)) return try self.parseWhile();
        if (self.check(.KeywordLoop)) return try self.parseLoop();
        if (self.check(.KeywordReturn)) return try self.parseReturn();
        if (self.check(.KeywordErr)) return try self.parseErr();
        if (self.check(.KeywordVal) or self.check(.KeywordVar)) return try self.parseVal(false);
        if (self.check(.KeywordMatch)) return try self.parseMatch();
        if (self.check(.KeywordBreak)) return try self.parseBreak();
        if (self.check(.KeywordContinue)) return try self.parseContinue();
        
        return try self.parseExpressionStmt();
    }
    
    fn parseIf(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordIf);

        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const condition = try expr_parser.parseExpression();

        _ = try self.consume(.OpenBrace);
        var then_block = std.ArrayListUnmanaged(*Node){};

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try self.parseStatement();
            try then_block.append(self.allocator, stmt);
        }

        _ = try self.consume(.CloseBrace);

        var else_block: ?[]const *Node = null;
        if (self.match(.KeywordElse)) {
            if (self.check(.KeywordIf)) {
                // else if: la rama else es un único if anidado
                const nested_if = try self.parseIf();
                var else_stmts = std.ArrayListUnmanaged(*Node){};
                try else_stmts.append(self.allocator, nested_if);
                else_block = try else_stmts.toOwnedSlice(self.allocator);
            } else {
                _ = try self.consume(.OpenBrace);
                var else_stmts = std.ArrayListUnmanaged(*Node){};
                while (!self.check(.CloseBrace) and !self.check(.EOF)) {
                    const stmt = try self.parseStatement();
                    try else_stmts.append(self.allocator, stmt);
                }
                _ = try self.consume(.CloseBrace);
                else_block = try else_stmts.toOwnedSlice(self.allocator);
            }
        }
        const then_node = try self.createNode(.block, .{ .block = .{ .stmts = try then_block.toOwnedSlice(self.allocator) } });

        var else_node: ?*Node = null;
        if (else_block) |eb| {
            const n = try self.createNode(.block, .{ .block = .{ .stmts = eb } });
            else_node = n;
        }

        const node = try self.createNode(.if_stmt, .{
            .if_stmt = .{
                .condition = condition,
                .then_branch = then_node,
                .else_branch = else_node,
            } ,
        });
        return node;
    }
    
    fn parseFor(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordFor);
        const item = try self.consume(.Identifier);
        _ = try self.consume(.KeywordIn);
        
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const iterable = try expr_parser.parseExpression();
        
        _ = try self.consume(.OpenBrace);
        var body = std.ArrayListUnmanaged(*Node){};
        
        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try self.parseStatement();
            try body.append(self.allocator, stmt);
        }
        
        _ = try self.consume(.CloseBrace);
        
        const body_node = try self.allocator.create(Node);
        body_node.* = .{
            .tag = .block,
            .data = .{ .block = .{ .stmts = try body.toOwnedSlice(self.allocator) } },
        };
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .for_stmt,
            .data = .{ .for_stmt = .{
                .item = item,
                .iterable = iterable,
                .body = body_node,
            } },
        };
        return node;
    }
    
    fn parseWhile(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordWhile);
        
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const condition = try expr_parser.parseExpression();
        
        _ = try self.consume(.OpenBrace);
        var body = std.ArrayListUnmanaged(*Node){};
        
        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try self.parseStatement();
            try body.append(self.allocator, stmt);
        }
        
        _ = try self.consume(.CloseBrace);
        
        const body_node = try self.allocator.create(Node);
        body_node.* = .{
            .tag = .block,
            .data = .{ .block = .{ .stmts = try body.toOwnedSlice(self.allocator) } },
        };
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .while_stmt,
            .data = .{ .while_stmt = .{
                .condition = condition,
                .body = body_node,
            } },
        };
        return node;
    }
    
    fn parseLoop(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordLoop);
        _ = try self.consume(.OpenBrace);
        
        var body = std.ArrayListUnmanaged(*Node){};
        
        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try self.parseStatement();
            try body.append(self.allocator, stmt);
        }
        
        _ = try self.consume(.CloseBrace);
        
        const body_node = try self.allocator.create(Node);
        body_node.* = .{
            .tag = .block,
            .data = .{ .block = .{ .stmts = try body.toOwnedSlice(self.allocator) } },
        };
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .loop_stmt,
            .data = .{ .loop_stmt = .{ .body = body_node } },
        };
        return node;
    }
    
    fn parseReturn(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordReturn);
        
        if (self.match(.KeywordOk)) {
            var status_tok: ?Token = null;
            if (self.check(.IntegerLiteral)) {
                status_tok = try self.consume(.IntegerLiteral);
            }
            var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
            const value = try expr_parser.parseExpression();

            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .return_ok,
                .data = .{ .return_ok = .{ .expr = value, .status = status_tok } },
            };
            _ = self.match(.SemiColon);
            return node;
        }

        var value: ?*Node = null;
        if (!self.check(.SemiColon) and !self.check(.CloseBrace)) {
            var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
            value = try expr_parser.parseExpression();
        }

        var status_tok: ?Token = null;
        if (self.match(.KeywordWith)) {
            _ = try self.consume(.Identifier); // "status"
            status_tok = try self.consume(.IntegerLiteral);
        }
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .return_stmt,
            .data = .{ .return_stmt = .{ .expr = value, .status = status_tok } },
        };
        
        _ = self.match(.SemiColon);
        return node;
    }

    fn parseErr(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordErr);
        const code = try self.consume(.IntegerLiteral);
        
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const message = try expr_parser.parseExpression();

        _ = self.match(.SemiColon);

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .err_stmt,
            .data = .{ .err_stmt = .{ .code = code, .message = message } },
        };
        return node;
    }
    
    pub fn parseVal(self: *StatementParser, is_private: bool) !*Node {
        if (self.check(.KeywordVar)) {
            _ = try self.consume(.KeywordVar);
        } else {
            _ = try self.consume(.KeywordVal);
        }
        const is_mut = self.match(.KeywordMut);
        const name = try self.consume(.Identifier);
        
        var type_ann_node: ?*Node = null;
        if (self.match(.Colon)) {
            const type_tok = self.current_token.*;
            self.advance(); // consume identifier or type keyword
            
            // Skip generics if any
            if (self.match(.Less)) {
                while (!self.check(.Greater) and !self.check(.EOF)) {
                    _ = self.advance(); // skip generic token
                }
                _ = try self.consume(.Greater);
            }
            // Skip optional
            _ = self.match(.Question);

            const t_node = try self.allocator.create(Node);
            t_node.* = .{
                .tag = .type_annotation,
                .data = .{ .type_annotation = .{
                    .base = type_tok,
                    .generics = &.{},
                    .is_optional = false,
                } },
            };
            type_ann_node = t_node;
        }
        
        var value: ?*Node = null;
        if (self.match(.Equal)) {
            var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
            value = try expr_parser.parseExpression();
        }
        _ = self.match(.SemiColon);
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .val_decl,
            .data = .{ .val_decl = .{
                .name = name,
                .value = value,
                .type_annotation = type_ann_node,
                .is_mut = is_mut,
                .is_private = is_private,
            } },
        };
        return node;
    }
    
    fn parseMatch(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordMatch);
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const expr = try expr_parser.parseExpression();

        _ = try self.consume(.OpenBrace);
        var cases = std.ArrayListUnmanaged(*Node){};

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const case = try self.parseMatchCase();
            try cases.append(self.allocator, case);
        }

        _ = try self.consume(.CloseBrace);

        return try self.createNode(.match_stmt, .{
            .match_stmt = .{ .expr = expr, .cases = try cases.toOwnedSlice(self.allocator) }
        });
    }

    fn parseMatchCase(self: *StatementParser) !*Node {
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const pattern = try expr_parser.parseExpression();

        _ = try self.consume(.FatArrow);

        const body = if (self.match(.OpenBrace)) blk: {
            var stmts = std.ArrayListUnmanaged(*Node){};
            while (!self.check(.CloseBrace) and !self.check(.EOF)) {
                try stmts.append(self.allocator, try self.parseStatement());
            }
            _ = try self.consume(.CloseBrace);
            const bn = try self.createNode(.block, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator) } });
            break :blk bn;
        } else try self.parseStatement();

        _ = self.match(.Comma);

        return try self.createNode(.match_case, .{
            .match_case = .{ .pattern = pattern, .body = body }
        });
    }

    fn parseExpressionStmt(self: *StatementParser) !*Node {
        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const expr = try expr_parser.parseExpression();
        
        _ = self.match(.SemiColon);
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .expression_stmt,
            .data = .{ .expression_stmt = .{ .expr = expr } },
        };
        return node;
    }

    fn parseBreak(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordBreak);
        _ = self.match(.SemiColon);
        return try self.createNode(.break_stmt, .{ .break_stmt = .{} });
    }

    fn parseContinue(self: *StatementParser) !*Node {
        _ = try self.consume(.KeywordContinue);
        _ = self.match(.SemiColon);
        return try self.createNode(.continue_stmt, .{ .continue_stmt = .{} });
    }
};
