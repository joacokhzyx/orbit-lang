const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ast = @import("ast.zig");
const Node = ast.Node;

const ExpressionParser = @import("parser/expression_parser.zig").ExpressionParser;
const StatementParser = @import("parser/statement_parser.zig").StatementParser;
const DeclarationParser = @import("parser/declaration_parser.zig").DeclarationParser;

pub const Parser = struct {
    lexer: Lexer,
    current_token: Token,
    previous_token: Token,
    allocator: std.mem.Allocator,
    source: []const u8,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Parser {
        var lexer = Lexer.init(source);
        const first_token = lexer.next();
        
        return .{
            .lexer = lexer,
            .current_token = first_token,
            .previous_token = first_token,
            .allocator = allocator,
            .source = source,
        };
    }

    fn advance(self: *Parser) void {
        self.previous_token = self.current_token;
        self.current_token = self.lexer.next();
    }

    fn peek(self: *Parser) TokenType {
        return self.current_token.tag;
    }

    fn check(self: *Parser, tag: TokenType) bool {
        return self.peek() == tag;
    }

    fn match(self: *Parser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }

    pub fn parse(self: *Parser) !*Node {
        var decls = std.ArrayListUnmanaged(*Node){};
        
        while (!self.check(.EOF)) {
            const decl = try self.parseTopLevel();
            try decls.append(self.allocator, decl);
        }
        
        const root = try self.allocator.create(Node);
        root.* = .{
            .tag = .root,
            .data = .{ .root = .{ .decls = try decls.toOwnedSlice(self.allocator) } },
        };
        return root;
    }

    fn parseTopLevel(self: *Parser) anyerror!*Node {
        var decorators = std.ArrayListUnmanaged(*Node){};
        
        while (self.check(.At)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            const dec = try decl_parser.parseDecorator();
            try decorators.append(self.allocator, dec);
        }
        
        const is_private = self.match(.KeywordPrivate);
        
        if (self.match(.KeywordImport)) {
             const path = self.current_token;
             self.advance();
             const node = try self.allocator.create(Node);
             node.* = .{
                 .tag = .import_stmt,
                 .data = .{ .import_stmt = .{ .path = path } },
             };
             return node;
        }

        if (self.match(.KeywordUse)) {
             const module = self.current_token;
             self.advance();
             const node = try self.allocator.create(Node);
             node.* = .{
                 .tag = .use_stmt,
                 .data = .{ .use_stmt = .{ .module = module } },
             };
             return node;
        }

        if (self.check(.KeywordModel)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            return try decl_parser.parseModel(is_private);
        }
        
        if (self.check(.KeywordRoute)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            return try decl_parser.parseRoute(try decorators.toOwnedSlice(self.allocator));
        }
        
        if (self.check(.KeywordFn) or self.check(.KeywordAsync)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            return try decl_parser.parseFunction(is_private);
        }
        
        if (self.check(.KeywordConst)) {
            return try self.parseConst(is_private);
        }
        
        if (self.check(.KeywordVal)) {
            var stmt_parser = StatementParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            return try stmt_parser.parseVal(is_private);
        }

        if (self.check(.KeywordType) or self.check(.KeywordEnum) or self.check(.KeywordUnion)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            return try decl_parser.parseTypeDecl(is_private);
        }
        
        var expr_parser = ExpressionParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
        const expr = try expr_parser.parseExpression();
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .expression_stmt,
            .data = .{ .expression_stmt = .{ .expr = expr } },
        };
        return node;
    }

    fn parseConst(self: *Parser, is_private: bool) !*Node {
        self.advance();
        const name = self.current_token;
        self.advance();
        self.advance();
        
        var expr_parser = ExpressionParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
        const value = try expr_parser.parseExpression();
        
        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .const_decl,
            .data = .{ .const_decl = .{
                .name = name,
                .value = value,
                .is_private = is_private,
            } },
        };
        return node;
    }
};

