const std = @import("std");

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
    KeywordConst,      // const (compile-time)
    KeywordVal,        // val (runtime immutable)
    KeywordVar,        // var (mutable)
    KeywordMut,        // mut modifier
    KeywordPrivate,    // private visibility
    KeywordFn,         // function
    KeywordAsync,      // async function
    KeywordAwait,      // await expression
    KeywordModel,      // model declaration
    KeywordRoute,      // route declaration
    KeywordRole,       // role definition
    KeywordReq,        // request body block

    // ============================================
    // KEYWORDS - Imports & Modules
    // ============================================
    KeywordUse,        // use db.sqlite
    KeywordImport,     // import './file.orb'

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
    KeywordErr,        // err 404 "message"
    KeywordOk,         // return ok "message"
    KeywordWith,       // with status 201

    // ============================================
    // KEYWORDS - Error Shortcuts
    // ============================================
    KeywordNotFound,      // not_found
    KeywordBadRequest,    // bad_request
    KeywordUnauthorized,  // unauthorized
    KeywordForbidden,     // forbidden
    KeywordConflict,      // conflict

    // ============================================
    // KEYWORDS - Boolean Literals
    // ============================================
    KeywordTrue,
    KeywordFalse,
    KeywordNull,

    // ============================================
    // KEYWORDS - Logic
    // ============================================
    KeywordAnd,        // and
    KeywordOr,         // or

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
    TypeArray,
    TypeMap,
    TypeSet,

    // ============================================
    // LITERALS
    // ============================================
    Identifier,
    StringLiteral,
    IntegerLiteral,
    FloatLiteral,

    // ============================================
    // OPERATORS - Arithmetic
    // ============================================
    Plus,          // +
    Minus,         // -
    Asterisk,      // *
    Slash,         // /
    Percent,       // %

    // ============================================
    // OPERATORS - Comparison
    // ============================================
    Equal,         // =
    DoubleEqual,   // ==
    NotEqual,      // !=
    Less,          // <
    LessEqual,     // <=
    Greater,       // >
    GreaterEqual,  // >=

    // ============================================
    // OPERATORS - Logical
    // ============================================
    DoublePipe,    // ||
    DoubleAmpersand, // &&
    Bang,          // !

    // ============================================
    // OPERATORS - Special
    // ============================================
    Question,      // ? (rescue operator)
    DoubleQuestion, // ?? (null coalescing)
    Arrow,         // ->
    FatArrow,      // =>
    At,            // @ (decorator)
    Pipe,          // |

    // ============================================
    // DELIMITERS
    // ============================================
    OpenBrace,     // {
    CloseBrace,    // }
    OpenParen,     // (
    CloseParen,    // )
    OpenBracket,   // [
    CloseBracket,  // ]
    Colon,         // :
    Dot,           // .
    Comma,         // ,
    SemiColon,     // ;

    // ============================================
    // COMPOUND ASSIGNMENT
    // ============================================
    PlusEqual,     // +=
    MinusEqual,    // -=
    StarEqual,     // *=
    SlashEqual,    // /=

    // ============================================
    // SPECIAL
    // ============================================
    EOF,
    Invalid,
    Newline,       // For statement termination if needed
};

pub const Token = struct {
    tag: TokenType,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
        line: usize,
        col: usize,
    };

    /// Get the source text for this token
    pub fn getText(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};
