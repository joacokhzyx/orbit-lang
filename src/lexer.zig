const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;

pub const Lexer = struct {
    source: []const u8,
    file_path: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,

    pub fn init(source: []const u8, file_path: []const u8) Lexer {
        return .{ .source = source, .file_path = file_path };
    }

    pub fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    pub fn peekNext(self: *Lexer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

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
            .{ "fn", .KeywordFn },
            .{ "async", .KeywordAsync },
            .{ "await", .KeywordAwait },
            .{ "model", .KeywordModel },
            .{ "route", .KeywordRoute },
            .{ "role", .KeywordRole },
            .{ "req", .KeywordReq },

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
    fn charLiteral(self: *Lexer, start: usize, line: usize, col: usize) Token {
        // La comilla de apertura ya fue consumida.
        if (self.peek() == '\\') {
            _ = self.advance(); // backslash
            _ = self.advance(); // char escapado
        } else if (self.peek() != '\'' and self.peek() != 0) {
            _ = self.advance();
        }

        if (self.peek() == '\'') {
            _ = self.advance();
            return .{ .tag = .CharLiteral, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
        }
        return .{ .tag = .Invalid, .loc = .{ .start = start, .end = self.pos, .line = line, .col = col }, .text = self.source[start..self.pos], .file_path = self.file_path, .file_source = self.source };
    }
    
    fn string(self: *Lexer, quote: u8, start: usize, line: usize, col: usize) Token {
    return self.stringWithTag(quote, start, line, col, .StringLiteral);
    }

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

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens = std.ArrayListUnmanaged(Token){};
        defer tokens.deinit(allocator);

        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.tag == .EOF) break;
        }
        return try tokens.toOwnedSlice(allocator);
    }
};

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
