//! Expression parser for the Orbit language.
//! Implements a Pratt-style recursive descent parser that produces
//! expression AST nodes for binary operations, unary operations,
//! function calls, member/index access, string interpolation, and
//! all primary literal forms (integers, floats, booleans, strings,
//! arrays, and object literals).

const std = @import("std");
const Lexer = @import("../lexer.zig").Lexer;
const token = @import("../token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ast = @import("../ast.zig");
const Node = ast.Node;

// ─── Parser struct ───────────────────────────────────────────────────────────

/// Recursive-descent expression parser.
///
/// Shares `lexer`, `current_token`, and `previous_token` with sibling
/// parsers so that token consumption is coherent when sub-parsers are
/// composed together.  All allocated nodes are tracked in `node_pool`
/// so that `deinit` can release them.
pub const ExpressionParser = struct {
    lexer: *Lexer,
    current_token: *Token,
    previous_token: *Token,
    allocator: std.mem.Allocator,
    source: []const u8,
    node_pool: std.ArrayListUnmanaged(*Node),

    /// Initialises an `ExpressionParser` with borrowed lexer/token pointers.
    /// The caller keeps ownership of the pointed-to values.
    pub fn init(lexer: *Lexer, current_token: *Token, previous_token: *Token, allocator: std.mem.Allocator, source: []const u8) ExpressionParser {
        return .{
            .lexer = lexer,
            .current_token = current_token,
            .previous_token = previous_token,
            .allocator = allocator,
            .source = source,
            .node_pool = .empty,
        };
    }

    /// Allocates a new `Node` with `tag` and `data`, appending it to the
    /// internal pool so that `deinit` can destroy it later.
    fn createNode(self: *ExpressionParser, tag: ast.Node.Tag, data: ast.Node.Data) !*Node {
        const node = try self.allocator.create(Node);
        try self.node_pool.append(self.allocator, node);
        node.* = .{
            .tag = tag,
            .data = data,
        };
        return node;
    }

    /// Releases all nodes that were created through this parser and frees the
    /// internal pool list.  Must be called when the parser is no longer needed
    /// and the AST nodes it produced are not referenced elsewhere.
    pub fn deinit(self: *ExpressionParser) void {
        for (self.node_pool.items) |node| {
            self.allocator.destroy(node);
        }
        self.node_pool.deinit(self.allocator);
    }

    // ─── Token navigation helpers ─────────────────────────────────────────

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

    // ─── Public entry point ───────────────────────────────────────────────

    /// Parses a complete expression starting at the current token position.
    /// This is the top-level entry point used by other parsers.
    pub fn parseExpression(self: *ExpressionParser) anyerror!*Node {
        return try self.parseAssignment();
    }

    // ─── Precedence levels (high → low) ──────────────────────────────────

    /// Parses an assignment expression (`target = value`), which is
    /// right-associative.  Falls through to `parseOr` when no `=` follows.
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

    /// Parses a logical-or expression (`||`), left-associative.
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

    /// Parses a logical-and expression (`&&`), left-associative.
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

    /// Parses equality/inequality expressions (`==`, `!=`), left-associative.
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

    /// Parses relational comparison expressions (`<`, `<=`, `>`, `>=`),
    /// left-associative.
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

    /// Parses additive expressions (`+`, `-`), left-associative.
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

    /// Parses multiplicative expressions (`*`, `/`), left-associative.
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

    /// Parses a unary prefix expression (`!`, unary `-`), right-associative.
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

    // ─── Postfix / call / member / index ─────────────────────────────────

    /// Parses postfix chains: function calls `(...)`, member access `.member`,
    /// index access `[expr]`, and rescue expressions `? err <code> <msg>`.
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

    /// Parses the argument list of a call expression whose opening `(` has
    /// already been consumed.  Supports both positional and named arguments
    /// (`name: value`).
    fn parseCall(self: *ExpressionParser, func: *Node) !*Node {
        var args = std.ArrayListUnmanaged(*Node).empty;

        if (!self.check(.CloseParen)) {
            while (true) {
                // Peek if it's a named argument
                if (self.check(.Identifier)) {
                    // We need to look ahead. Since we only have current_token,
                    // we can't easily peek the NEXT token without consuming this one.
                    // But we can match the identifier and then check the next token.
                    const id_tok = self.current_token.*;

                    // Skip whitespace in the raw source to determine if a colon follows.
                    var p = self.lexer.pos;
                    while (p < self.lexer.source.len and std.ascii.isWhitespace(self.lexer.source[p])) {
                        p += 1;
                    }

                    if (p < self.lexer.source.len and self.lexer.source[p] == ':') {
                        // Named argument: consume identifier and colon, then parse value
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

    // ─── String interpolation ─────────────────────────────────────────────

    /// Parses an interpolated string token (e.g. `"Hello {name}!"`) and
    /// desugars it into a tree of binary `+` concatenation nodes.
    fn parseInterpolatedString(self: *ExpressionParser, tok: Token) anyerror!*Node {
        const src = self.source;
        const content_start = tok.loc.start + 1; // after the opening quote
        const content_end = tok.loc.end - 1;     // the closing quote (exclusive)

        // Synthetic '+' token: only the .tag matters in the active (IR) path
        const plus_tok = Token{ .tag = .Plus, .loc = .{
            .start = tok.loc.start, .end = tok.loc.start, .line = tok.loc.line, .col = tok.loc.col,
        } };

        var result: ?*Node = null;
        var lit_start = content_start;
        var i = content_start;

        while (i < content_end) {
            const c = src[i];
            if (c == '\\' and i + 1 < content_end) { i += 2; continue; } // skip escapes (\{, \")
            if (c == '{') {
                const lit_node = try self.makeChunkNode(lit_start, i);
                result = try self.appendConcat(result, lit_node, plus_tok);

                const parsed = try self.parseEmbeddedExpr(i + 1);
                result = try self.appendConcat(result, parsed.node, plus_tok);

                i = parsed.stop + 1; // skip the '}'
                lit_start = i;
                continue;
            }
            i += 1;
        }

        const tail = try self.makeChunkNode(lit_start, content_end);
        result = try self.appendConcat(result, tail, plus_tok);

        return result.?;
    }

    /// Concatenates `left` and `right` with a binary `+` node.  When `left`
    /// is `null` (first segment), `right` is returned directly.
    fn appendConcat(self: *ExpressionParser, left: ?*Node, right: *Node, op: Token) !*Node {
        if (left == null) return right;
        return try self.createNode(.binary_op, .{ .binary_op = .{ .lhs = left.?, .op = op, .rhs = right } });
    }

    /// Creates a `string_literal` node whose source location covers
    /// `src[c0..c1)`, adjusted so that the IR slice `[1..len-1]` correctly
    /// strips the surrounding quote characters.
    fn makeChunkNode(self: *ExpressionParser, c0: usize, c1: usize) !*Node {
        const chunk_tok = Token{ .tag = .StringLiteral, .loc = .{
            .start = c0 - 1, .end = c1 + 1, .line = 0, .col = 0,
        } };
        return try self.createNode(.string_literal, .{ .string_literal = chunk_tok });
    }

    /// Parses the expression inside a `{...}` interpolation block starting at
    /// absolute source offset `abs_start`.  Uses a fresh sub-lexer positioned
    /// at `abs_start` so that source locations are valid for code generation.
    fn parseEmbeddedExpr(self: *ExpressionParser, abs_start: usize) anyerror!struct { node: *Node, stop: usize } {
        var sub_lexer = Lexer.init(self.source, self.current_token.file_path);
        sub_lexer.pos = abs_start; // point into the real source => valid locs for codegen
        var cur: Token = sub_lexer.next();
        var prev: Token = cur;
        var sub = ExpressionParser.init(&sub_lexer, &cur, &prev, self.allocator, self.source);
        const node = try sub.parseExpression();
        return .{ .node = node, .stop = cur.loc.start }; // cur = '}' that ended the expression
    }

    // ─── Primary expressions ──────────────────────────────────────────────

    /// Parses a primary expression: integer/float/char/bool/string literals,
    /// identifiers, parenthesised expressions, array literals, and object
    /// literals.  Returns `error.UnexpectedToken` when no primary form is
    /// recognised.
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

    /// Parses an array literal `[elem, ...]` after the opening `[` has been
    /// consumed.
    fn parseArrayLiteral(self: *ExpressionParser) !*Node {
        var elements = std.ArrayListUnmanaged(*Node).empty;

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

    /// Parses an object literal `{ key: value, ... }` after the opening `{`
    /// has been consumed.  Keys may be string literals or identifiers.
    fn parseObjectLiteral(self: *ExpressionParser) !*Node {
        var fields = std.ArrayListUnmanaged(*Node).empty;

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

    // ─── Token classification helpers ─────────────────────────────────────

    /// Returns `true` if the current token is a valid member-access target
    /// (identifier or certain keyword tokens that appear as property names).
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

    /// Returns `true` if `tag` represents a named HTTP-error shortcut keyword
    /// (`notFound`, `badRequest`, `unauthorized`, `forbidden`, `conflict`).
    fn isErrorShortcutToken(tag: TokenType) bool {
        return tag == .KeywordNotFound or
            tag == .KeywordBadRequest or
            tag == .KeywordUnauthorized or
            tag == .KeywordForbidden or
            tag == .KeywordConflict;
    }
};
