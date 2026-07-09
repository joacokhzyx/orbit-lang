const std = @import("std");
const Lexer = @import("../lexer.zig").Lexer;
const token = @import("../token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ast = @import("../ast.zig");
const Node = ast.Node;

pub const ExpressionParser = struct {
    lexer: *Lexer,
    current_token: *Token,
    previous_token: *Token,
    allocator: std.mem.Allocator,
    source: []const u8,
    node_pool: std.ArrayListUnmanaged(*Node),

    pub fn init(lexer: *Lexer, current_token: *Token, previous_token: *Token, allocator: std.mem.Allocator, source: []const u8) ExpressionParser {
        return .{
            .lexer = lexer,
            .current_token = current_token,
            .previous_token = previous_token,
            .allocator = allocator,
            .source = source,
            .node_pool = .{},
        };
    }

    fn createNode(self: *ExpressionParser, tag: ast.Node.Tag, data: ast.Node.Data) !*Node {
        const node = try self.allocator.create(Node);
        try self.node_pool.append(self.allocator, node);
        node.* = .{
            .tag = tag,
            .data = data,
        };
        return node;
    }

    // Other methods remain the same but use createNode instead of direct allocation

    pub fn deinit(self: *ExpressionParser) void {
        for (self.node_pool.items) |node| {
            self.allocator.destroy(node);
        }
        self.node_pool.deinit(self.allocator);
    }
    
    fn advance(self: *ExpressionParser) void {
        self.previous_token.* = self.current_token.*;
        self.current_token.* = self.lexer.next();
    }
    
    fn check(self: *ExpressionParser, tag: TokenType) bool {
        return self.current_token.tag == tag;
    }
    
    fn match(self: *ExpressionParser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }
    
    fn consume(self: *ExpressionParser, tag: TokenType) !Token {
        if (self.current_token.tag == tag) {
            const tok = self.current_token.*;
            self.advance();
            return tok;
        }
        return error.UnexpectedToken;
    }
    
    pub fn parseExpression(self: *ExpressionParser) anyerror!*Node {
        return try self.parseAssignment();
    }
    
    fn parseAssignment(self: *ExpressionParser) anyerror!*Node {
        const left = try self.parseOr();
        
        if (self.match(.Equal)) {
            const right = try self.parseAssignment(); // Right-associative
            
            return try self.createNode(.assignment, .{ .assignment = .{
                .target = left,
                .value = right,
            } });
        }
        
        return left;
    }
    
    fn parseOr(self: *ExpressionParser) !*Node {
        var left = try self.parseAnd();

        while (self.match(.DoublePipe)) {
            const op = self.previous_token.*;
            const right = try self.parseAnd();

            const node = try self.createNode(.binary_op, .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } });
            left = node;
        }

        return left;
    }
    
    fn parseAnd(self: *ExpressionParser) !*Node {
        var left = try self.parseEquality();
        
        while (self.match(.DoubleAmpersand)) {
            const op = self.previous_token.*;
            const right = try self.parseEquality();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .binary_op,
                .data = .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } },
            };
            left = node;
        }
        
        return left;
    }
    
    fn parseEquality(self: *ExpressionParser) !*Node {
        var left = try self.parseComparison();
        
        while (self.match(.DoubleEqual) or self.match(.NotEqual)) {
            const op = self.previous_token.*;
            const right = try self.parseComparison();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .binary_op,
                .data = .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } },
            };
            left = node;
        }
        
        return left;
    }
    
    fn parseComparison(self: *ExpressionParser) !*Node {
        var left = try self.parseTerm();
        
        while (self.match(.Less) or self.match(.LessEqual) or 
               self.match(.Greater) or self.match(.GreaterEqual)) {
            const op = self.previous_token.*;
            const right = try self.parseTerm();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .binary_op,
                .data = .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } },
            };
            left = node;
        }
        
        return left;
    }
    
    fn parseTerm(self: *ExpressionParser) !*Node {
        var left = try self.parseFactor();
        
        while (self.match(.Plus) or self.match(.Minus)) {
            const op = self.previous_token.*;
            const right = try self.parseFactor();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .binary_op,
                .data = .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } },
            };
            left = node;
        }
        
        return left;
    }
    
    fn parseFactor(self: *ExpressionParser) !*Node {
        var left = try self.parseUnary();
        
        while (self.match(.Asterisk) or self.match(.Slash)) {
            const op = self.previous_token.*;
            const right = try self.parseUnary();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .binary_op,
                .data = .{ .binary_op = .{ .lhs = left, .op = op, .rhs = right } },
            };
            left = node;
        }
        
        return left;
    }
    
    fn parseUnary(self: *ExpressionParser) !*Node {
        if (self.match(.Bang) or self.match(.Minus)) {
            const op = self.previous_token.*;
            const right = try self.parseUnary();
            
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .unary_op,
                .data = .{ .unary_op = .{ .op = op, .operand = right } },
            };
            return node;
        }
        
        return try self.parsePostfix();
    }
    
    fn parsePostfix(self: *ExpressionParser) !*Node {
        var expr = try self.parsePrimary();
        
        while (true) {
            if (self.match(.OpenParen)) {
                expr = try self.parseCall(expr);
            } else if (self.match(.Dot)) {
                if (!self.isMemberToken()) return error.UnexpectedToken;
                const member = self.current_token.*;
                self.advance();
                
                const node = try self.allocator.create(Node);
                node.* = .{
                    .tag = .member_access,
                    .data = .{ .member_access = .{ .object = expr, .member = member } },
                };
                expr = node;
            } else if (self.match(.OpenBracket)) {
                const index = try self.parseExpression();
                _ = try self.consume(.CloseBracket);
                const node = try self.allocator.create(Node);
                node.* = .{
                    .tag = .index_access,
                    .data = .{ .index_access = .{ .object = expr, .index = index } },
                };
                expr = node;
            } else if (self.match(.Question)) {
                var error_kind = self.previous_token.*;
                var err_handler: *Node = undefined;

                // Accept bootstrap-friendly syntax: value ? err 404 "message"
                if (self.match(.KeywordErr)) {
                    error_kind = self.previous_token.*;
                    if (self.check(.IntegerLiteral)) {
                        _ = try self.consume(.IntegerLiteral);
                    }
                    err_handler = try self.parseExpression();
                } else {
                    if (isErrorShortcutToken(self.current_token.tag)) {
                        error_kind = self.current_token.*;
                    }
                    err_handler = try self.parseExpression();
                    if (error_kind.tag == .Question) {
                        error_kind = self.previous_token.*;
                    }
                }

                const node = try self.allocator.create(Node);
                node.* = .{
                    .tag = .rescue_expr,
                    .data = .{ .rescue_expr = .{ .expr = expr, .error_kind = error_kind, .message = err_handler } },
                };
                expr = node;
            } else {
                break;
            }
        }
        
        return expr;
    }
    
    fn parseCall(self: *ExpressionParser, func: *Node) !*Node {
        var args = std.ArrayListUnmanaged(*Node){};

        if (!self.check(.CloseParen)) {
            while (true) {
                // Peek if it's a named argument
                if (self.check(.Identifier)) {
                    // We need to look ahead. Since we only have current_token,
                    // we can't easily peek the NEXT token without consuming this one.
                    // But we can match the identifier and then check the next token.
                    const id_tok = self.current_token.*;
                    
                    // To avoid complex backtracking, let's just peek the lexer properly.
                    // We need to skip whitespace manually if we peek characters.
                    var p = self.lexer.pos;
                    while (p < self.lexer.source.len and std.ascii.isWhitespace(self.lexer.source[p])) {
                        p += 1;
                    }
                    
                    if (p < self.lexer.source.len and self.lexer.source[p] == ':') {
                        // It IS a named argument
                        _ = try self.consume(.Identifier); // id_tok
                        _ = try self.consume(.Colon);
                        const value = try self.parseExpression();
                        const named_arg = try self.createNode(.field_init, .{ .field_init = .{ .name = id_tok, .value = value } });
                        try args.append(self.allocator, named_arg);
                    } else {
                        // Not a named argument, just a normal expression
                        const arg = try self.parseExpression();
                        try args.append(self.allocator, arg);
                    }
                } else {
                    const arg = try self.parseExpression();
                    try args.append(self.allocator, arg);
                }

                if (!self.match(.Comma)) break;
            }
        }

        _ = try self.consume(.CloseParen);

        const node = try self.createNode(.call, .{ .call = .{ .func = func, .args = try args.toOwnedSlice(self.allocator) } });
        return node;
    }
    
    fn parseInterpolatedString(self: *ExpressionParser, tok: Token) anyerror!*Node {
        const src = self.source;
        const content_start = tok.loc.start + 1; // después de la comilla de apertura
        const content_end = tok.loc.end - 1;     // la comilla de cierre (exclusivo)

        // '+' sintético: en la ruta activa (IR) solo importa el .tag
        const plus_tok = Token{ .tag = .Plus, .loc = .{
            .start = tok.loc.start, .end = tok.loc.start, .line = tok.loc.line, .col = tok.loc.col,
        } };

        var result: ?*Node = null;
        var lit_start = content_start;
        var i = content_start;

        while (i < content_end) {
            const c = src[i];
            if (c == '\\' and i + 1 < content_end) { i += 2; continue; } // saltar escapes (\{, \")
            if (c == '{') {
                const lit_node = try self.makeChunkNode(lit_start, i);
                result = try self.appendConcat(result, lit_node, plus_tok);

                const parsed = try self.parseEmbeddedExpr(i + 1);
                result = try self.appendConcat(result, parsed.node, plus_tok);

                i = parsed.stop + 1; // saltar el '}'
                lit_start = i;
                continue;
            }
            i += 1;
        }

        const tail = try self.makeChunkNode(lit_start, content_end);
        result = try self.appendConcat(result, tail, plus_tok);

        return result.?;
    }

    fn appendConcat(self: *ExpressionParser, left: ?*Node, right: *Node, op: Token) !*Node {
        if (left == null) return right;
        return try self.createNode(.binary_op, .{ .binary_op = .{ .lhs = left.?, .op = op, .rhs = right } });
    }

    // Crea un string_literal cuyo slice [1..len-1] (el que recorta el IR) == src[c0..c1)
    fn makeChunkNode(self: *ExpressionParser, c0: usize, c1: usize) !*Node {
        const chunk_tok = Token{ .tag = .StringLiteral, .loc = .{
            .start = c0 - 1, .end = c1 + 1, .line = 0, .col = 0,
        } };
        return try self.createNode(.string_literal, .{ .string_literal = chunk_tok });
    }

    fn parseEmbeddedExpr(self: *ExpressionParser, abs_start: usize) anyerror!struct { node: *Node, stop: usize } {
        var sub_lexer = Lexer.init(self.source, self.current_token.file_path);
        sub_lexer.pos = abs_start; // apunta al source real => locs válidos para codegen
        var cur: Token = sub_lexer.next();
        var prev: Token = cur;
        var sub = ExpressionParser.init(&sub_lexer, &cur, &prev, self.allocator, self.source);
        const node = try sub.parseExpression();
        return .{ .node = node, .stop = cur.loc.start }; // cur = '}' que terminó la expresión
    }

    fn parsePrimary(self: *ExpressionParser) !*Node {
        if (self.match(.IntegerLiteral)) {
            const node = try self.createNode(.integer_literal, .{ .integer_literal = self.previous_token.* });
            return node;
        }
        if (self.match(.CharLiteral)) {
            const node = try self.createNode(.char_literal, .{ .char_literal = self.previous_token.* });
            return node;
        }
        if (self.match(.FloatLiteral)) {
            const node = try self.createNode(.float_literal, .{ .float_literal = self.previous_token.* });
            return node;
        }

        if (self.match(.StringLiteral)) {
            const node = try self.createNode(.string_literal, .{ .string_literal = self.previous_token.* });
            return node;
        }

        if (self.match(.InterpStringLiteral)) {
            return try self.parseInterpolatedString(self.previous_token.*);
        }

        if (self.match(.KeywordTrue) or self.match(.KeywordFalse)) {
            const node = try self.createNode(.boolean_literal, .{ .boolean_literal = self.previous_token.* });
            return node;
        }

        if (self.match(.Identifier) or self.match(.KeywordOk) or self.match(.KeywordErr)) {
            const node = try self.createNode(.identifier, .{ .identifier = self.previous_token.* });
            return node;
        }
        
        if (self.match(.OpenParen)) {
            const expr = try self.parseExpression();
            _ = try self.consume(.CloseParen);
            return expr;
        }
        
        if (self.match(.OpenBracket)) {
            return try self.parseArrayLiteral();
        }
        
        if (self.match(.OpenBrace)) {
            return try self.parseObjectLiteral();
        }
        
        return error.UnexpectedToken;
    }
    
    fn parseArrayLiteral(self: *ExpressionParser) !*Node {
        var elements = std.ArrayListUnmanaged(*Node){};

        if (!self.check(.CloseBracket)) {
            while (true) {
                const elem = try self.parseExpression();
                try elements.append(self.allocator, elem);

                if (!self.match(.Comma)) break;
            }
        }

        _ = try self.consume(.CloseBracket);

        const node = try self.createNode(.array_literal, .{ .array_literal = .{ .elements = try elements.toOwnedSlice(self.allocator) } });
        return node;
    }
    
    fn parseObjectLiteral(self: *ExpressionParser) !*Node {
        var fields = std.ArrayListUnmanaged(*Node){};

        if (!self.check(.CloseBrace)) {
            while (true) {
                var key: Token = undefined;
                if (self.check(.StringLiteral)) {
                    key = try self.consume(.StringLiteral);
                } else {
                    key = try self.consume(.Identifier);
                }
                _ = try self.consume(.Colon);
                const value = try self.parseExpression();

                const field_node = try self.createNode(.field_init, .{ .field_init = .{ .name = key, .value = value } });
                try fields.append(self.allocator, field_node);

                if (!self.match(.Comma)) break;
            }
        }

        _ = try self.consume(.CloseBrace);

        const node = try self.createNode(.object_literal, .{ .object_literal = .{ .fields = try fields.toOwnedSlice(self.allocator) } });
        return node;
    }
    fn isMemberToken(self: *ExpressionParser) bool {
        const t = self.current_token.tag;
        return t == .Identifier or 
               t == .KeywordGet or t == .KeywordPost or t == .KeywordPut or t == .KeywordDelete or
               t == .KeywordPatch or t == .KeywordHead or t == .KeywordOptions or
               t == .KeywordType or t == .KeywordEnum or t == .KeywordUnion or t == .KeywordModel or
               t == .KeywordMatch or t == .KeywordReturn or t == .KeywordFn or
               t == .KeywordOk or t == .KeywordErr or t == .KeywordVal or t == .KeywordConst or
               t == .KeywordPrivate or t == .KeywordAsync or t == .KeywordAwait;
    }

    fn isErrorShortcutToken(tag: TokenType) bool {
        return tag == .KeywordNotFound or
            tag == .KeywordBadRequest or
            tag == .KeywordUnauthorized or
            tag == .KeywordForbidden or
            tag == .KeywordConflict;
    }
};
