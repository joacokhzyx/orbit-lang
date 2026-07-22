//! Lexer for the Orbit language.
//!
//! Transforms raw source text into a flat stream of `Token` values.
//! Handles identifiers, keywords, numeric and string literals, operators,
//! block/line comments, and interpolated strings (`$"..."`).
//! The `Lexer` struct is purely positional — it owns no heap allocation.

const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;

// ─── Lexer ───────────────────────────────────────────────────────────────────

/// Stateful lexer that walks a UTF-8 source buffer and emits tokens one at a time.
pub const Lexer = struct {
    source: []const u8,
    file_path: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,

    /// Initialises a new `Lexer` positioned at the start of `source`.
    pub fn init(source: []const u8, file_path: []const u8) Lexer {
        return .{ .source = source, .file_path = file_path };
    }

    /// Returns the byte at the current position without consuming it.
    /// Returns `0` when the end of source has been reached.
    pub fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    /// Returns the byte one position ahead of the cursor without consuming it.
    /// Returns `0` if that position is past the end of source.
    pub fn peekNext(self: *Lexer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    /// Advances the cursor by one byte, updating line/column tracking.
    /// Returns the consumed byte, or `0` at end-of-source.
    fn advance(self: *Lexer) u8 {
        const char = self.peek();
        if (self.pos >= self.source.len) return 0;
        self.pos += 1;
        if (char == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return char;
    }

    /// Scans and returns the next token from the source stream.
    /// Whitespace and comments are skipped automatically before each token.
    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        const start = self.pos;
        const line = self.line;
        const col = self.col;

        const char = self.advance();

        if (char == 0) return self.makeToken(.EOF, start);

        if (std.ascii.isAlphabetic(char) or char == '_') {
            return self.identifier(start, line, col);
        }

        if (std.ascii.isDigit(char)) {
            return self.number(start, line, col);
        }

        return switch (char) {
            '{' => self.makeToken(.OpenBrace, start),
            '}' => self.makeToken(.CloseBrace, start),
            '(' => self.makeToken(.OpenParen, start),
            ')' => self.makeToken(.CloseParen, start),
            '[' => self.makeToken(.OpenBracket, start),
            ']' => self.makeToken(.CloseBracket, start),
            ':' => self.makeToken(.Colon, start),
            '.' => self.makeToken(.Dot, start),
            ';' => self.makeToken(.SemiColon, start),
            ',' => self.makeToken(.Comma, start),
            '@' => self.makeToken(.At, start),
            '%' => self.makeToken(.Percent, start),

            '=' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.DoubleEqual, start);
                } else if (self.peek() == '>') {
                    _ = self.advance();
                    break :blk self.makeToken(.FatArrow, start);
                }
                break :blk self.makeToken(.Equal, start);
            },

            '!' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.NotEqual, start);
                }
                break :blk self.makeToken(.Bang, start);
            },

            '<' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.LessEqual, start);
                }
                break :blk self.makeToken(.Less, start);
            },

            '>' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.GreaterEqual, start);
                }
                break :blk self.makeToken(.Greater, start);
            },

            '+' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.PlusEqual, start);
                }
                break :blk self.makeToken(.Plus, start);
            },

            '-' => blk: {
                if (self.peek() == '>') {
                    _ = self.advance();
                    break :blk self.makeToken(.Arrow, start);
                } else if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.MinusEqual, start);
                }
                break :blk self.makeToken(.Minus, start);
            },

            '*' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.StarEqual, start);
                }
                break :blk self.makeToken(.Asterisk, start);
            },

            '/' => blk: {
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk self.makeToken(.SlashEqual, start);
                }
                break :blk self.makeToken(.Slash, start);
            },

            '|' => blk: {
                if (self.peek() == '|') {
                    _ = self.advance();
                    break :blk self.makeToken(.DoublePipe, start);
                }
                break :blk self.makeToken(.Pipe, start);
            },

            '&' => blk: {
                if (self.peek() == '&') {
                    _ = self.advance();
                    break :blk self.makeToken(.DoubleAmpersand, start);
                }
                break :blk self.makeToken(.Invalid, start);
            },

            '?' => blk: {
                if (self.peek() == '?') {
                    _ = self.advance();
                    break :blk self.makeToken(.DoubleQuestion, start);
                }
                break :blk self.makeToken(.Question, start);
            },
            '"' => self.string(char, start, line, col),
            '\'' => self.charLiteral(start, line, col),
            '$' => blk: {
                if (self.peek() == '"') {
                    const q_start = self.pos;
                    _ = self.advance();
                    break :blk self.stringWithTag('"', q_start, line, col, .InterpStringLiteral);
                }
                break :blk self.makeToken(.Invalid, start);
            },

            else => self.makeToken(.Invalid, start),
        };
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// Constructs a `Token` spanning `[start, self.pos)` in the source buffer.
    fn makeToken(self: *Lexer, tag: TokenType, start: usize) Token {
        return .{
            .tag = tag,
            .loc = .{
                .start = start,
                .end = self.pos,
                .line = self.line,
                .col = self.col,
            },
            .text = self.source[start..self.pos],
            .file_path = self.file_path,
            .file_source = self.source,
        };
    }

    /// Skips whitespace characters and both line (`//`) and block (`/* */`) comments.
    fn skipWhitespace(self: *Lexer) void {
        while (true) {
            const char = self.peek();
            switch (char) {
                ' ', '\t', '\r', '\n' => {
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        while (self.peek() != '\n' and self.peek() != 0) {
                            _ = self.advance();
                        }
                    } else if (self.peekNext() == '*') {
                        _ = self.advance();
                        _ = self.advance();
                        while (true) {
                            if (self.peek() == 0) break;
                            if (self.peek() == '*' and self.peekNext() == '/') {
                                _ = self.advance();
                                _ = self.advance();
                                break;
                            }
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    /// Scans a full identifier or keyword starting at `start` and returns the
    /// appropriate token (resolves keywords via `checkKeyword`).
    fn identifier(self: *Lexer, start: usize, line: usize, col: usize) Token {
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            _ = self.advance();
        }

        const text = self.source[start..self.pos];
        const tag = checkKeyword(text);

        return .{
            .tag = tag,
            .loc = .{
                .start = start,
                .end = self.pos,
                .line = line,
                .col = col,
            },
            .text = text,
            .file_path = self.file_path,
            .file_source = self.source,
        };
    }

    /// Maps an identifier string to its keyword `TokenType`, or `.Identifier`
    /// if the text is not a reserved word.
    fn checkKeyword(text: []const u8) TokenType {
        const keywords = std.StaticStringMap(TokenType).initComptime(.{
            .{ "if", .KeywordIf },
            .{ "else", .KeywordElse },
            .{ "for", .KeywordFor },
            .{ "in", .KeywordIn },
            .{ "while", .KeywordWhile },
            .{ "loop", .KeywordLoop },
            .{ "break", .KeywordBreak },
            .{ "continue", .KeywordContinue },
            .{ "return", .KeywordReturn },
            .{ "match", .KeywordMatch },
            .{ "type", .KeywordType },
            .{ "enum", .KeywordEnum },
            .{ "union", .KeywordUnion },

            .{ "const", .KeywordConst },
            .{ "val", .KeywordVal },
            .{ "var", .KeywordVar },
            .{ "mut", .KeywordMut },
            .{ "private", .KeywordPrivate },
            .{ "extern", .KeywordExtern },
            .{ "fn", .KeywordFn },
            .{ "async", .KeywordAsync },
            .{ "await", .KeywordAwait },
            .{ "model", .KeywordModel },
            .{ "route", .KeywordRoute },
            .{ "role", .KeywordRole },
            .{ "req", .KeywordReq },
            .{ "every", .KeywordEvery },

            .{ "use", .KeywordUse },
            .{ "import", .KeywordImport },

            .{ "GET", .KeywordGet },
            .{ "POST", .KeywordPost },
            .{ "PUT", .KeywordPut },
            .{ "PATCH", .KeywordPatch },
            .{ "DELETE", .KeywordDelete },
            .{ "HEAD", .KeywordHead },
            .{ "OPTIONS", .KeywordOptions },

            .{ "err", .KeywordErr },
            .{ "ok", .KeywordOk },
            .{ "with", .KeywordWith },

            .{ "not_found", .KeywordNotFound },
            .{ "bad_request", .KeywordBadRequest },
            .{ "unauthorized", .KeywordUnauthorized },
            .{ "forbidden", .KeywordForbidden },
            .{ "conflict", .KeywordConflict },

            .{ "true", .KeywordTrue },
            .{ "false", .KeywordFalse },
            .{ "null", .KeywordNull },

            .{ "and", .KeywordAnd },
            .{ "or", .KeywordOr },

            .{ "string", .TypeString },
            .{ "int", .TypeInt },
            .{ "float", .TypeFloat },
            .{ "bool", .TypeBool },
            .{ "decimal", .TypeDecimal },

            .{ "Email", .TypeEmail },
            .{ "URL", .TypeURL },
            .{ "UUID", .TypeUUID },
            .{ "Phone", .TypePhone },
            .{ "IP", .TypeIP },
            .{ "Date", .TypeDate },
            .{ "Time", .TypeTime },
            .{ "DateTime", .TypeDateTime },
            .{ "Timestamp", .TypeTimestamp },

            .{ "list", .TypeList },
            .{ "map", .TypeMap },
            .{ "set", .TypeSet },
        });

        return keywords.get(text) orelse .Identifier;
    }

    /// Scans an integer or floating-point literal beginning at `start`.
    /// A decimal point followed by another digit triggers float mode.
    fn number(self: *Lexer, start: usize, line: usize, col: usize) Token {
        var is_float = false;
        while (std.ascii.isDigit(self.peek())) {
            _ = self.advance();
        }

        if (self.peek() == '.' and self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1])) {
            is_float = true;
            _ = self.advance();
            while (std.ascii.isDigit(self.peek())) {
                _ = self.advance();
            }
        }

        return .{
            .tag = if (is_float) .FloatLiteral else .IntegerLiteral,
            .loc = .{
                .start = start,
                .end = self.pos,
                .line = line,
                .col = col,
            },
            .text = self.source[start..self.pos],
            .file_path = self.file_path,
            .file_source = self.source,
        };
    }

    /// Scans a single-character literal enclosed in single quotes (`'c'`).
    /// Supports standard escape sequences such as `\n`, `\t`, `\\`, and `\'`.
    fn charLiteral(self: *Lexer, start: usize, line: usize, col: usize) Token {
        // The opening quote was already consumed by `next`.
        if (self.peek() == '\\') {
            _ = self.advance(); // backslash
            _ = self.advance(); // escaped char
        } else if (self.peek() != '\'' and self.peek() != 0) {
            _ = self.advance();
        }

        if (self.peek() == '\'') {
            _ = self.advance();
            return .{ .tag = .CharLiteral, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
        }
        return .{ .tag = .Invalid, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
    }

    /// Scans a plain double-quoted string literal and delegates to `stringWithTag`.
    fn string(self: *Lexer, quote: u8, start: usize, line: usize, col: usize) Token {
        return self.stringWithTag(quote, start, line, col, .StringLiteral);
    }

    /// Scans a string literal delimited by `quote`, tagging the result with `tag`.
    /// Used for both plain strings (`.StringLiteral`) and interpolated strings
    /// (`.InterpStringLiteral`). Handles backslash escape sequences.
    fn stringWithTag(self: *Lexer, quote: u8, start: usize, line: usize, col: usize, tag: TokenType) Token {
        while (self.peek() != quote and self.peek() != 0) {
            if (self.peek() == '\\' and self.peekNext() != 0) {
                _ = self.advance();
            }
            _ = self.advance();
        }

        if (self.peek() == quote) {
            _ = self.advance();
            return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
        }

        return .{ .tag = .Invalid, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
    }

    // ─── Batch tokenisation ───────────────────────────────────────────────────

    /// Tokenises the entire source buffer and returns a heap-allocated slice of
    /// all tokens including the terminal `EOF` token.
    /// The caller owns the returned slice and must free it with `allocator.free`.
    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens = std.ArrayListUnmanaged(Token).empty;
        defer tokens.deinit(allocator);

        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.tag == .EOF) break;
        }
        return try tokens.toOwnedSlice(allocator);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "lexer basic tokens" {
    const source = "val x = 42";
    var lexer = Lexer.init(source, "test.orb");

    const tok1 = lexer.next();
    try std.testing.expectEqual(TokenType.KeywordVal, tok1.tag);

    const tok2 = lexer.next();
    try std.testing.expectEqual(TokenType.Identifier, tok2.tag);

    const tok3 = lexer.next();
    try std.testing.expectEqual(TokenType.Equal, tok3.tag);

    const tok4 = lexer.next();
    try std.testing.expectEqual(TokenType.IntegerLiteral, tok4.tag);
}

test "lexer operators" {
    const source = "|| && ?? => ->";
    var lexer = Lexer.init(source, "test.orb");

    try std.testing.expectEqual(TokenType.DoublePipe, lexer.next().tag);
    try std.testing.expectEqual(TokenType.DoubleAmpersand, lexer.next().tag);
    try std.testing.expectEqual(TokenType.DoubleQuestion, lexer.next().tag);
    try std.testing.expectEqual(TokenType.FatArrow, lexer.next().tag);
    try std.testing.expectEqual(TokenType.Arrow, lexer.next().tag);
}

test "lexer http methods" {
    const source = "GET POST PUT DELETE";
    var lexer = Lexer.init(source, "test.orb");

    try std.testing.expectEqual(TokenType.KeywordGet, lexer.next().tag);
    try std.testing.expectEqual(TokenType.KeywordPost, lexer.next().tag);
    try std.testing.expectEqual(TokenType.KeywordPut, lexer.next().tag);
    try std.testing.expectEqual(TokenType.KeywordDelete, lexer.next().tag);
}

test "lexer comments" {
    const source = "val x = 1 // this is a comment\nval y = 2";
    var lexer = Lexer.init(source, "test.orb");

    try std.testing.expectEqual(TokenType.KeywordVal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.Identifier, lexer.next().tag);
    try std.testing.expectEqual(TokenType.Equal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.IntegerLiteral, lexer.next().tag);
    try std.testing.expectEqual(TokenType.KeywordVal, lexer.next().tag);
}
