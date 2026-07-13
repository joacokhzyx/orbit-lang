//! Token definitions for the Orbit language lexer.
//!
//! Defines `TokenType` — an exhaustive enumeration of every token kind
//! recognised by the Orbit lexer — and `Token`, the lightweight value type
//! that carries a type tag, source location, and a slice of the original
//! source text.  Both types are used throughout the parser and semantic
//! analysis phases.

const std = @import("std");

// ─── TokenType ───────────────────────────────────────────────────────────────

/// Every distinct token kind produced by the Orbit lexer.
///
/// Variants are grouped into logical sections: control-flow keywords,
/// declaration keywords, HTTP-method keywords, error-handling keywords,
/// built-in type names, literal kinds, operators, delimiters, and specials.
pub const TokenType = enum {
    // ============================================
    // KEYWORDS - Control Flow
    // ============================================
    KeywordIf,
    KeywordElse,
    KeywordFor,
    KeywordIn,
    KeywordWhile,
    KeywordLoop,
    KeywordBreak,
    KeywordContinue,
    KeywordReturn,
    KeywordMatch,
    KeywordType,
    KeywordEnum,
    KeywordUnion,

    // ============================================
    // KEYWORDS - Declarations
    // ============================================
    KeywordConst, // const (compile-time)
    KeywordVal, // val (runtime immutable)
    KeywordVar, // var (mutable)
    KeywordMut, // mut modifier
    KeywordPrivate, // private visibility
    KeywordFn, // function
    KeywordAsync, // async function
    KeywordAwait, // await expression
    KeywordModel, // model declaration
    KeywordRoute, // route declaration
    KeywordRole, // role definition
    KeywordReq, // request body block

    // ============================================
    // KEYWORDS - Imports & Modules
    // ============================================
    KeywordUse, // use db.sqlite
    KeywordImport, // import './file.orb'

    // ============================================
    // KEYWORDS - HTTP Methods
    // ============================================
    KeywordGet,
    KeywordPost,
    KeywordPut,
    KeywordPatch,
    KeywordDelete,
    KeywordHead,
    KeywordOptions,

    // ============================================
    // KEYWORDS - Error Handling
    // ============================================
    KeywordErr, // err 404 "message"
    KeywordOk, // return ok "message"
    KeywordWith, // with status 201

    // ============================================
    // KEYWORDS - Error Shortcuts
    // ============================================
    KeywordNotFound, // not_found
    KeywordBadRequest, // bad_request
    KeywordUnauthorized, // unauthorized
    KeywordForbidden, // forbidden
    KeywordConflict, // conflict

    // ============================================
    // KEYWORDS - Boolean Literals
    // ============================================
    KeywordTrue,
    KeywordFalse,
    KeywordNull,

    // ============================================
    // KEYWORDS - Logic
    // ============================================
    KeywordAnd, // and
    KeywordOr, // or

    // ============================================
    // TYPES - Primitives
    // ============================================
    TypeString,
    TypeInt,
    TypeFloat,
    TypeBool,
    TypeDecimal,

    // ============================================
    // TYPES - Validated
    // ============================================
    TypeEmail,
    TypeURL,
    TypeUUID,
    TypePhone,
    TypeIP,
    TypeDate,
    TypeTime,
    TypeDateTime,
    TypeTimestamp,

    // ============================================
    // TYPES - Collections
    // ============================================
    TypeList,
    TypeMap,
    TypeSet,

    // ============================================
    // LITERALS
    // ============================================
    Identifier,
    StringLiteral,
    IntegerLiteral,
    FloatLiteral,
    CharLiteral,
    InterpStringLiteral,

    // ============================================
    // OPERATORS - Arithmetic
    // ============================================
    Plus, // +
    Minus, // -
    Asterisk, // *
    Slash, // /
    Percent, // %

    // ============================================
    // OPERATORS - Comparison
    // ============================================
    Equal, // =
    DoubleEqual, // ==
    NotEqual, // !=
    Less, // <
    LessEqual, // <=
    Greater, // >
    GreaterEqual, // >=

    // ============================================
    // OPERATORS - Logical
    // ============================================
    DoublePipe, // ||
    DoubleAmpersand, // &&
    Bang, // !

    // ============================================
    // OPERATORS - Special
    // ============================================
    Question, // ? (rescue operator)
    DoubleQuestion, // ?? (null coalescing)
    Arrow, // ->
    FatArrow, // =>
    At, // @ (decorator)
    Pipe, // |

    // ============================================
    // DELIMITERS
    // ============================================
    OpenBrace, // {
    CloseBrace, // }
    OpenParen, // (
    CloseParen, // )
    OpenBracket, // [
    CloseBracket, // ]
    Colon, // :
    Dot, // .
    Comma, // ,
    SemiColon, // ;

    // ============================================
    // COMPOUND ASSIGNMENT
    // ============================================
    PlusEqual, // +=
    MinusEqual, // -=
    StarEqual, // *=
    SlashEqual, // /=

    // ============================================
    // SPECIAL
    // ============================================
    EOF,
    Invalid,
    Newline, // For statement termination if needed
};

// ─── Token ───────────────────────────────────────────────────────────────────

/// A single lexical token produced by the Orbit lexer.
///
/// A token stores its `TokenType` tag, a `Loc` describing its byte range and
/// line/column position in the original source, a direct slice of the source
/// text (`text`), and references to the originating file for error reporting.
pub const Token = struct {
    tag: TokenType,
    loc: Loc,
    text: []const u8 = "", // Direct slice into the source buffer
    file_path: []const u8 = "", // Path of the file being lexed
    file_source: []const u8 = "", // Full source text of the file

    /// Source location of a token: byte offsets and human-readable line/column.
    pub const Loc = struct {
        start: usize,
        end: usize,
        line: usize,
        col: usize,
    };

    /// Returns the source text for this token.
    /// The `source` parameter is accepted for API compatibility but is unused —
    /// the token already carries a direct slice of the source buffer.
    pub fn getText(self: Token, source: []const u8) []const u8 {
        _ = source;
        return self.text;
    }

    /// Decodes a `.CharLiteral` token into its Unicode code point as an `i64`.
    /// Handles common escape sequences: `\n`, `\t`, `\r`, `\0`, `\\`, `\'`, `\"`.
    pub fn charCode(self: Token, source: []const u8) i64 {
        _ = source;
        const text = self.text;
        if (text.len < 3) return 0;
        const inner = text[1 .. text.len - 1];
        if (inner[0] != '\\') return @as(i64, inner[0]);
        return switch (inner[1]) {
            'n' => 10,
            't' => 9,
            'r' => 13,
            '0' => 0,
            '\\' => 92,
            '\'' => 39,
            '"' => 34,
            else => @as(i64, inner[1]),
        };
    }
};
