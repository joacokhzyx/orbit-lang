//! Top-level parser entry-point for the Orbit language.
//!
//! `Parser` coordinates the three specialised sub-parsers
//! (`ExpressionParser`, `StatementParser`, `DeclarationParser`) that live
//! under `src/parser/`.  It is responsible for iterating the token stream,
//! dispatching each top-level form to the appropriate sub-parser, and
//! returning a fully-formed `Node.root` AST node.

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

// ─── Parser ───────────────────────────────────────────────────────────────────

/// Recursive-descent parser that transforms an Orbit source file into an AST.
///
/// The parser operates in a single pass over the token stream produced by the
/// embedded `Lexer`.  Helper sub-parsers handle expressions, statements, and
/// declarations; `Parser` itself owns the token cursor state shared between
/// all of them via pointer arguments.
pub const Parser = struct {
    lexer: Lexer,
    current_token: Token,
    previous_token: Token,
    allocator: std.mem.Allocator,
    source: []const u8,

    /// Creates a `Parser` for `source`, pre-loading the first token so the
    /// cursor is immediately ready for `parse()`.
    pub fn init(source: []const u8, file_path: []const u8, allocator: std.mem.Allocator) Parser {
        var lexer = Lexer.init(source, file_path);
        const first_token = lexer.next();

        return .{
            .lexer = lexer,
            .current_token = first_token,
            .previous_token = first_token,
            .allocator = allocator,
            .source = source,
        };
    }

    /// Moves the cursor one token forward, saving the old current token as
    /// `previous_token`.
    fn advance(self: *Parser) void {
        self.previous_token = self.current_token;
        self.current_token = self.lexer.next();
    }

    /// Returns the `TokenType` of the current (un-consumed) token.
    fn peek(self: *Parser) TokenType {
        return self.current_token.tag;
    }

    /// Returns `true` if the current token has the given `tag`.
    fn check(self: *Parser, tag: TokenType) bool {
        return self.peek() == tag;
    }

    /// Consumes the current token and returns `true` if it matches `tag`;
    /// returns `false` and leaves the cursor unchanged otherwise.
    fn match(self: *Parser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }

    /// Parses the entire source file and returns a `Node.root` node whose
    /// `decls` slice contains every top-level declaration in order.
    pub fn parse(self: *Parser) !*Node {
        var decls = std.ArrayListUnmanaged(*Node).empty;

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

    // ─── Top-level dispatch ───────────────────────────────────────────────────

    /// Parses one top-level declaration or expression statement, collecting any
    /// leading decorator annotations and the optional `private` visibility
    /// modifier before dispatching to the appropriate sub-parser.
    fn parseTopLevel(self: *Parser) anyerror!*Node {
        var decorators = std.ArrayListUnmanaged(*Node).empty;

        while (self.check(.At)) {
            var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            const dec = try decl_parser.parseDecorator();
            try decorators.append(self.allocator, dec);
        }

        if (decorators.items.len > 0 and self.match(.OpenBrace)) {
            var group_nodes = std.ArrayListUnmanaged(*Node).empty;
            const group_decs = try decorators.toOwnedSlice(self.allocator);
            while (!self.check(.CloseBrace) and !self.check(.EOF)) {
                if (self.check(.KeywordRoute)) {
                    var decl_parser = DeclarationParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
                    const r_node = try decl_parser.parseRoute(group_decs);
                    try group_nodes.append(self.allocator, r_node);
                } else {
                    const inner_node = try self.parseTopLevel();
                    try group_nodes.append(self.allocator, inner_node);
                }
            }
            _ = self.match(.CloseBrace);
            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .block,
                .data = .{ .block = .{ .stmts = try group_nodes.toOwnedSlice(self.allocator) } },
            };
            return node;
        }

        const is_private = self.match(.KeywordPrivate);
        const is_extern = self.match(.KeywordExtern);

        if (self.check(.Identifier)) {
            const tok_text = self.current_token.text;
            if (std.mem.eql(u8, tok_text, "port") or std.mem.eql(u8, tok_text, "cors") or std.mem.eql(u8, tok_text, "db") or std.mem.eql(u8, tok_text, "env")) {
                const key = self.current_token;
                self.advance();
                var expr_parser = ExpressionParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
                const val = try expr_parser.parseExpression();

                const node = try self.allocator.create(Node);
                node.* = .{
                    .tag = .config_decl,
                    .data = .{ .config_decl = .{
                        .key = key,
                        .value = val,
                    } },
                };
                return node;
            }
        }

        if (self.match(.KeywordEvery)) {
            const amount = self.current_token;
            self.advance();
            const unit = self.current_token;
            self.advance();
            var at_time: ?Token = null;
            if (self.current_token.tag == .Identifier and std.mem.eql(u8, self.current_token.text, "at")) {
                self.advance();
                at_time = self.current_token;
                self.advance();
            }
            _ = self.match(.FatArrow);
            var expr_parser = ExpressionParser.init(&self.lexer, &self.current_token, &self.previous_token, self.allocator, self.source);
            const handler = try expr_parser.parseExpression();

            const node = try self.allocator.create(Node);
            node.* = .{
                .tag = .schedule_decl,
                .data = .{ .schedule_decl = .{
                    .amount = amount,
                    .unit = unit,
                    .at_time = at_time,
                    .handler = handler,
                } },
            };
            return node;
        }

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
            return try decl_parser.parseFunction(is_private, is_extern);
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

    /// Parses a `const NAME = EXPR` declaration with the given visibility flag.
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
