//! Declaration parser for the Orbit language.
//! Handles top-level declarations such as models, routes, functions,
//! decorators, and type aliases (including enum and union variants).
//! Works in tandem with `StatementParser` and `ExpressionParser`,
//! sharing lexer state through pointer references.

const std = @import("std");
const token = @import("../token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ast = @import("../ast.zig");
const Node = ast.Node;
const Lexer = @import("../lexer.zig").Lexer;
const StatementParser = @import("statement_parser.zig").StatementParser;
const ExpressionParser = @import("expression_parser.zig").ExpressionParser;

// ─── Parser struct ───────────────────────────────────────────────────────────

/// Parses top-level declarations in an Orbit source file.
///
/// All three parser types (`DeclarationParser`, `StatementParser`,
/// `ExpressionParser`) share the same `lexer`, `current_token`, and
/// `previous_token` pointers so that token consumption is consistent
/// across sub-parsers.
pub const DeclarationParser = struct {
    lexer: *Lexer,
    current_token: *Token,
    previous_token: *Token,
    allocator: std.mem.Allocator,
    source: []const u8,

    /// Creates a `DeclarationParser` that borrows the given lexer and token
    /// pointers.  The caller is responsible for keeping those pointers valid
    /// for the lifetime of this parser.
    pub fn init(lexer: *Lexer, current_token: *Token, previous_token: *Token, allocator: std.mem.Allocator, source: []const u8) DeclarationParser {
        return .{
            .lexer = lexer,
            .current_token = current_token,
            .previous_token = previous_token,
            .allocator = allocator,
            .source = source,
        };
    }

    // ─── Internal helpers ─────────────────────────────────────────────────

    fn advance(self: *DeclarationParser) void {
        self.previous_token.* = self.current_token.*;
        self.current_token.* = self.lexer.next();
    }

    fn check(self: *DeclarationParser, tag: TokenType) bool {
        return self.current_token.tag == tag;
    }

    fn match(self: *DeclarationParser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *DeclarationParser, tag: TokenType) !Token {
        if (self.current_token.tag == tag) {
            const tok = self.current_token.*;
            self.advance();
            return tok;
        }
        return error.UnexpectedToken;
    }

    // ─── Model declarations ───────────────────────────────────────────────

    /// Parses a `model <Name> { ... }` declaration and returns the
    /// corresponding `model_decl` AST node.
    ///
    /// `is_private` controls whether the model is visible outside its
    /// compilation unit.
    pub fn parseModel(self: *DeclarationParser, is_private: bool) !*Node {
        _ = try self.consume(.KeywordModel);
        const name = try self.consume(.Identifier);
        _ = try self.consume(.OpenBrace);

        var fields = std.ArrayListUnmanaged(*Node).empty;

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const field = try self.parseFieldDecl();
            try fields.append(self.allocator, field);
            _ = self.match(.Comma);
        }

        _ = try self.consume(.CloseBrace);

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .model_decl,
            .data = .{ .model_decl = .{
                .name = name,
                .fields = try fields.toOwnedSlice(self.allocator),
                .is_private = is_private,
            } },
        };
        return node;
    }

    // ─── Type helpers ─────────────────────────────────────────────────────

    /// Consumes an optional generic parameter list `<T, U>` and a trailing
    /// `?` optionality marker after the base type token has already been
    /// consumed.
    fn consumeTypeTail(self: *DeclarationParser) anyerror!void {
        // Skip generics: <T, U>
        if (self.match(.Less)) {
            while (!self.check(.Greater) and !self.check(.EOF)) {
                _ = try self.consumeType(); // Recurse for nested generics
                _ = self.match(.Comma);
            }
            _ = try self.consume(.Greater);
        }

        // Skip optional: ?
        _ = self.match(.Question);
    }

    /// Consumes a complete type expression (identifier or built-in type
    /// keyword) including any generic tail and optional marker.
    ///
    /// Returns the leading type token.  Errors with `error.ExpectedType` if
    /// no type token is found at the current position.
    fn consumeType(self: *DeclarationParser) anyerror!Token {
        if (self.check(.Identifier) or
            self.isTypeToken()) {
            const tok = self.current_token.*;
            self.advance();
            try self.consumeTypeTail();
            return tok;
        }
        return error.ExpectedType;
    }

    // ─── Field declarations ───────────────────────────────────────────────

    /// Parses a single model field declaration, including any leading
    /// decorator annotations, the field name, colon-separated type, and
    /// an optional default value expression.
    fn parseFieldDecl(self: *DeclarationParser) !*Node {
        var decorators = std.ArrayListUnmanaged(*Node).empty;

        while (self.check(.At)) {
            const dec = try self.parseDecorator();
            try decorators.append(self.allocator, dec);
        }

        const name = try self.consume(.Identifier);
        _ = try self.consume(.Colon);
        const type_name = try self.consumeType();

        var default_val: ?*Node = null;
        if (self.match(.Equal)) {
            var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
            default_val = try expr_parser.parseExpression();
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .field_decl,
            .data = .{ .field_decl = .{
                .name = name,
                .type_name = type_name,
                .decorators = try decorators.toOwnedSlice(self.allocator),
                .default_value = default_val,
            } },
        };
        return node;
    }

    // ─── Parameter parsing ────────────────────────────────────────────────

    /// Parses a single function or route parameter of the form
    /// `name` or `name: Type`.
    fn parseParam(self: *DeclarationParser) !*Node {
        const name = try self.consume(.Identifier);

        var type_name: ?Token = null;
        if (self.match(.Colon)) {
            type_name = try self.consumeType();
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .param,
            .data = .{ .param = .{
                .name = name,
                .type_name = type_name,
                .is_optional = false,
            } },
        };
        return node;
    }

    // ─── Route declarations ───────────────────────────────────────────────

    /// Parses a `route <METHOD> "<path>" { ... }` declaration.
    ///
    /// `decorators` is the slice of decorator nodes that were already parsed
    /// before the `route` keyword was encountered.
    pub fn parseRoute(self: *DeclarationParser, decorators: []const *Node) !*Node {
        _ = try self.consume(.KeywordRoute);

        const method = self.current_token.*;
        if (!self.isHttpMethod()) {
            return error.ExpectedHttpMethod;
        }
        self.advance();

        const path = try self.consume(.StringLiteral);

        var params = std.ArrayListUnmanaged(*Node).empty;

        var body = std.ArrayListUnmanaged(*Node).empty;
        _ = try self.consume(.OpenBrace);

        var stmt_parser = StatementParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try stmt_parser.parseStatement();
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
            .tag = .route_decl,
            .data = .{ .route_decl = .{
                .method = method,
                .path = path,
                .params = try params.toOwnedSlice(self.allocator),
                .decorators = decorators,
                .body = body_node,
            } },
        };
        return node;
    }

    // ─── Function declarations ────────────────────────────────────────────

    /// Parses a function declaration of the form
    /// `[async] fn <name>(<params>) [-> ReturnType] { <body> }`.
    ///
    /// `is_private` marks the function as module-private when true.
    pub fn parseFunction(self: *DeclarationParser, is_private: bool) !*Node {
        const is_async = self.match(.KeywordAsync);
        _ = try self.consume(.KeywordFn);
        const name = try self.consume(.Identifier);
        _ = try self.consume(.OpenParen);

        var params = std.ArrayListUnmanaged(*Node).empty;

        if (!self.check(.CloseParen)) {
            while (true) {
                const param = try self.parseParam();
                try params.append(self.allocator, param);

                if (!self.match(.Comma)) break;
            }
        }

        _ = try self.consume(.CloseParen);

        var return_type: ?Token = null;
        if (self.match(.Arrow)) {
            return_type = try self.consumeType();
        }

        _ = try self.consume(.OpenBrace);
        var body = std.ArrayListUnmanaged(*Node).empty;

        var stmt_parser = StatementParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const stmt = try stmt_parser.parseStatement();
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
            .tag = .fn_decl,
            .data = .{ .fn_decl = .{
                .name = name,
                .params = try params.toOwnedSlice(self.allocator),
                .return_type = return_type,
                .body = body_node,
                .is_async = is_async,
                .is_private = is_private,
            } },
        };
        return node;
    }

    // ─── Decorator declarations ───────────────────────────────────────────

    /// Parses a decorator annotation of the form `@<name>` or
    /// `@<name>(<args>)` and returns the corresponding `decorator` node.
    pub fn parseDecorator(self: *DeclarationParser) !*Node {
        _ = try self.consume(.At);
        const name = try self.consume(.Identifier);

        var args = std.ArrayListUnmanaged(*Node).empty;
        if (self.match(.OpenParen)) {
            if (!self.check(.CloseParen)) {
                var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);

                while (true) {
                    const arg = try expr_parser.parseExpression();
                    try args.append(self.allocator, arg);

                    if (!self.match(.Comma)) break;
                }
            }
            _ = try self.consume(.CloseParen);
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .decorator,
            .data = .{ .decorator = .{ .name = name, .args = try args.toOwnedSlice(self.allocator) } },
        };
        return node;
    }

    // ─── Type alias / enum / union declarations ───────────────────────────

    /// Parses a type declaration which may be one of:
    /// - `enum <Name> { ... }`
    /// - `union <Name> { ... }`
    /// - `type <Name> = <expr | enum | union>`
    ///
    /// Returns the appropriate AST node for the resolved form.
    pub fn parseTypeDecl(self: *DeclarationParser, is_private: bool) !*Node {
        if (self.match(.KeywordEnum)) {
            const name = try self.consume(.Identifier);
            return try self.parseEnumDecl(name, is_private);
        }

        if (self.match(.KeywordUnion)) {
            const name = try self.consume(.Identifier);
            return try self.parseUnionDecl(name, is_private);
        }

        _ = try self.consume(.KeywordType);
        const name = try self.consume(.Identifier);
        _ = try self.consume(.Equal);

        if (self.match(.KeywordEnum)) {
            return try self.parseEnumDecl(name, is_private);
        }

        if (self.match(.KeywordUnion)) {
            return try self.parseUnionDecl(name, is_private);
        }

        var expr_parser = ExpressionParser.init(self.lexer, self.current_token, self.previous_token, self.allocator, self.source);
        const target = try expr_parser.parseExpression();

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .type_decl,
            .data = .{ .type_decl = .{ .name = name, .target_type = target, .is_private = is_private } },
        };
        return node;
    }

    /// Parses the body of an enum declaration `{ Variant, ... }` using the
    /// already-consumed `name` token.
    fn parseEnumDecl(self: *DeclarationParser, name: Token, is_private: bool) !*Node {
        _ = try self.consume(.OpenBrace);
        var variants = std.ArrayListUnmanaged(Token).empty;

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            var variant: Token = undefined;
            if (self.check(.Identifier)) {
                variant = try self.consume(.Identifier);
            } else if (self.isHttpMethod()) {
                variant = self.current_token.*;
                self.advance();
            } else {
                return error.ExpectedVariant;
            }
            try variants.append(self.allocator, variant);
            _ = self.match(.Comma); // optional comma
        }

        _ = try self.consume(.CloseBrace);

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .enum_decl,
            .data = .{ .enum_decl = .{
                .name = name,
                .variants = try variants.toOwnedSlice(self.allocator),
                .is_private = is_private,
            } },
        };
        return node;
    }

    /// Parses the body of a union declaration `{ Variant[(Payload)], ... }`
    /// using the already-consumed `name` token.
    ///
    /// Each variant may optionally carry a single payload type enclosed in
    /// parentheses: `Variant(Type)` or `Variant(field: Type)`.
    fn parseUnionDecl(self: *DeclarationParser, name: Token, is_private: bool) !*Node {
        _ = try self.consume(.OpenBrace);
        var variants = std.ArrayListUnmanaged(*Node).empty;

        while (!self.check(.CloseBrace) and !self.check(.EOF)) {
            const v_name = try self.consume(.Identifier);

            var payload: ?*Node = null;
            if (self.match(.OpenParen)) {
                // Supports both Variant(Type) and Variant(name: Type).
                // For Variant(a: A, b: B), we keep first payload for now and parse the rest for syntax compatibility.
                if (!self.check(.CloseParen)) {
                    const first_payload = try self.consumeUnionVariantPayloadType();
                    const p_node = try self.allocator.create(Node);
                    p_node.* = .{ .tag = .identifier, .data = .{ .identifier = first_payload } };
                    payload = p_node;

                    while (self.match(.Comma)) {
                        _ = try self.consumeUnionVariantPayloadType();
                    }
                }

                _ = try self.consume(.CloseParen);
            }

            const v_node = try self.allocator.create(Node);
            v_node.* = .{
                .tag = .union_variant,
                .data = .{ .union_variant = .{ .name = v_name, .payload = payload } }
            };

            try variants.append(self.allocator, v_node);
            _ = self.match(.Comma); // optional comma
        }

        _ = try self.consume(.CloseBrace);

        const node = try self.allocator.create(Node);
        node.* = .{
            .tag = .union_decl,
            .data = .{ .union_decl = .{
                .name = name,
                .variants = try variants.toOwnedSlice(self.allocator),
                .is_private = is_private,
            } },
        };
        return node;
    }

    /// Consumes a single union variant payload type, handling both the
    /// `name: Type` (named field) and bare `Type` forms.
    fn consumeUnionVariantPayloadType(self: *DeclarationParser) anyerror!Token {
        if (self.check(.Identifier)) {
            const first = self.current_token.*;
            self.advance();

            if (self.match(.Colon)) {
                return try self.consumeType();
            }

            try self.consumeTypeTail();
            return first;
        }

        if (self.isTypeToken()) {
            return try self.consumeType();
        }

        return error.ExpectedType;
    }

    // ─── Token classification helpers ─────────────────────────────────────

    /// Returns `true` if the current token is one of the Orbit built-in
    /// primitive type keywords (e.g. `string`, `int`, `list`).
    fn isTypeToken(self: *DeclarationParser) bool {
        const tag = self.current_token.tag;
        return tag == .TypeString or tag == .TypeInt or tag == .TypeFloat or
               tag == .TypeBool or tag == .TypeDecimal or tag == .TypeEmail or
               tag == .TypeURL or tag == .TypeUUID or tag == .TypePhone or
               tag == .TypeIP or tag == .TypeDate or tag == .TypeTime or
               tag == .TypeDateTime or tag == .TypeTimestamp or tag == .TypeList or
               tag == .TypeMap or tag == .TypeSet;
    }

    /// Returns `true` if the current token is an HTTP method keyword
    /// (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`).
    fn isHttpMethod(self: *DeclarationParser) bool {
        return self.check(.KeywordGet) or self.check(.KeywordPost) or
               self.check(.KeywordPut) or self.check(.KeywordPatch) or
               self.check(.KeywordDelete) or self.check(.KeywordHead) or
               self.check(.KeywordOptions);
    }
};
