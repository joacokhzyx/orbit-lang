const std = @import("std");
pub const Token = @import("token.zig").Token;

/// Main AST Node structure
pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        // ============================================
        // TOP-LEVEL DECLARATIONS
        // ============================================
        root,           // Program root
        use_stmt,       // use db.sqlite
        import_stmt,    // import './file.orb'
        model_decl,     // model User { ... }
        route_decl,     // route GET "/path" { ... }
        fn_decl,        // fn name() { ... }
        role_decl,      // role admin = condition
        const_decl,     // const X = value
        val_decl,       // val x = value
        type_decl,      // type Name = Type
        enum_decl,      // type Name = enum { ... }
        union_decl,     // type Name = union { ... }

        // ============================================
        // STATEMENTS
        // ============================================
        block,          // { ... }
        expression_stmt,
        return_stmt,    // return value
        return_ok,      // return ok value
        err_stmt,       // err 404 "message"
        err_shortcut,   // not_found "message"
        if_stmt,
        match_stmt,     // match expr { variant => ... }
        for_stmt,       // for item in collection
        while_stmt,
        loop_stmt,
        assignment,     // x = value
        req_block,      // req { name: string }
        break_stmt,
        continue_stmt,

        // ============================================
        // EXPRESSIONS
        // ============================================
        binary_op,
        unary_op,
        call,
        member_access,
        index_access,
        rescue_expr,    // value ? error "msg"
        null_coalesce,  // value ?? default
        await_expr,     // await expr
        arrow_fn,       // (x) => expr

        // ============================================
        // LITERALS
        // ============================================
        identifier,
        string_literal,
        integer_literal,
        float_literal,
        boolean_literal,
        null_literal,
        array_literal,
        object_literal,

        // ============================================
        // HELPERS
        // ============================================
        field_decl,     // In models: name: Type
        param,          // Function parameter
        field_init,     // In objects: name: value
        decorator,      // @admin
        type_annotation,
        match_case,     // variant(params) => block
        union_variant,  // variant(Type)
    };

    pub const Data = union {
        // ============================================
        // TOP-LEVEL
        // ============================================
        root: struct {
            decls: []const *Node,
        },

        use_stmt: struct {
            module: Token,  // The module path (e.g., "db.sqlite")
        },

        import_stmt: struct {
            path: Token,    // The file path
        },

        model_decl: struct {
            name: Token,
            fields: []const *Node,
            is_private: bool,
        },

        route_decl: struct {
            method: Token,
            path: Token,
            params: ?[]const *Node,  // Inline params (a: Type, b: Type)
            decorators: []const *Node,
            body: *Node,
        },

        fn_decl: struct {
            name: Token,
            params: []const *Node,
            return_type: ?Token,
            body: *Node,
            is_async: bool,
            is_private: bool,
        },

        role_decl: struct {
            name: Token,
            params: []const *Node,  // Role params like owner(id)
            condition: *Node,
        },

        const_decl: struct {
            name: Token,
            value: *Node,
            is_private: bool,
        },

        val_decl: struct {
            name: Token,
            value: ?*Node,
            type_annotation: ?*Node,
            is_mut: bool,
            is_private: bool,
        },
        
        type_decl: struct {
            name: Token,
            target_type: *Node,
            is_private: bool,
        },

        enum_decl: struct {
             name: Token,
             variants: []const Token,
             is_private: bool,
        },

        union_decl: struct {
            name: Token,
            variants: []const *Node, // Each variant can be a struct-like declaration
            is_private: bool,
        },

        // ============================================
        // STATEMENTS
        // ============================================
        block: struct {
            stmts: []const *Node,
        },

        return_stmt: struct {
            expr: ?*Node,
            status: ?Token,  // "with status 201"
        },

        return_ok: struct {
            expr: *Node,
            status: ?Token,
        },

        err_stmt: struct {
            code: Token,     // Status code (404)
            message: *Node,  // Error message
        },

        err_shortcut: struct {
            kind: Token,     // not_found, bad_request, etc.
            message: *Node,
        },

        if_stmt: struct {
            condition: *Node,
            then_branch: *Node,
            else_branch: ?*Node,
        },
        
        match_stmt: struct {
            expr: *Node,
            cases: []const *Node, // Each case is a branch
        },

        for_stmt: struct {
            item: Token,
            iterable: *Node,
            body: *Node,
        },

        while_stmt: struct {
            condition: *Node,
            body: *Node,
        },

        loop_stmt: struct {
            body: *Node,
        },

        assignment: struct {
            target: *Node,
            value: *Node,
        },

        req_block: struct {
            fields: []const *Node,
            var_name: ?Token,  // If assigned to variable
        },

        break_stmt: struct {},
        continue_stmt: struct {},

        // ============================================
        // EXPRESSIONS
        // ============================================
        binary_op: struct {
            lhs: *Node,
            op: Token,
            rhs: *Node,
        },

        unary_op: struct {
            op: Token,
            operand: *Node,
        },

        call: struct {
            func: *Node,
            args: []const *Node,
        },

        member_access: struct {
            object: *Node,
            member: Token,
        },

        index_access: struct {
            object: *Node,
            index: *Node,
        },

        rescue_expr: struct {
            expr: *Node,
            error_kind: Token,  // not_found, etc.
            message: *Node,
        },

        null_coalesce: struct {
            expr: *Node,
            default: *Node,
        },

        await_expr: struct {
            expr: *Node,
        },

        arrow_fn: struct {
            params: []const Token,
            body: *Node,
            is_expr: bool,  // Single expression vs block
        },

        // ============================================
        // LITERALS
        // ============================================
        identifier: Token,
        string_literal: Token,
        integer_literal: Token,
        float_literal: Token,
        boolean_literal: Token,
        null_literal: void,

        array_literal: struct {
            elements: []const *Node,
        },

        object_literal: struct {
            fields: []const *Node,
        },

        // ============================================
        // HELPERS
        // ============================================
        field_decl: struct {
            name: Token,
            type_name: Token,
            decorators: []const *Node,
            default_value: ?*Node,
        },

        param: struct {
            name: Token,
            type_name: ?Token,
            is_optional: bool,
        },

        field_init: struct {
            name: Token,
            value: *Node,
        },

        decorator: struct {
            name: Token,
            args: []const *Node,
        },

        type_annotation: struct {
            base: Token,
            generics: []const Token,
            is_optional: bool,
        },

        // Expression statement (wraps expr)
        expression_stmt: struct {
            expr: *Node,
        },

        match_case: struct {
            pattern: *Node, // can be identifier or call-like Root(decls)
            body: *Node,
        },
        
        union_variant: struct {
            name: Token,
            payload: ?*Node,
        },
    };


    /// Helper to get token text from source
    pub fn getTokenText(tok: Token, source: []const u8) []const u8 {
        return source[tok.loc.start..tok.loc.end];
    }
};

/// Program is the root of the AST
pub const Program = struct {
    nodes: []const *Node,
    source: []const u8,

    pub fn init(nodes: []const *Node, source: []const u8) Program {
        return .{
            .nodes = nodes,
            .source = source,
        };
    }
};
