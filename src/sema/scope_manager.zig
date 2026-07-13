//! Lexical scope management for the Orbit semantic analyser.
//! Provides `Scope` (a single symbol table with a parent pointer for chained
//! look-up) and `ScopeManager` (a stack-based controller that opens and
//! closes scopes as the analyser enters and leaves blocks).

const std = @import("std");

/// A single entry recorded in a `Scope`.  Tracks the declared name, its
/// resolved type string, mutability, and whether it is a function binding.
pub const ScopeEntry = struct {
    name: []const u8,
    type_name: []const u8,
    is_mut: bool,
    is_function: bool,
    has_return: bool,
};

/// A symbol table for one lexical scope, with an optional pointer to the
/// enclosing parent scope.  Look-up walks the parent chain automatically.
pub const Scope = struct {
    entries: std.StringHashMapUnmanaged(ScopeEntry),
    parent: ?*Scope,
    allocator: std.mem.Allocator,

    /// Creates an empty scope with an optional `parent` scope for name
    /// resolution fall-through.
    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .entries = .empty,
            .parent = parent,
            .allocator = allocator,
        };
    }

    /// Releases the internal entry map.  Does not touch the parent scope.
    pub fn deinit(self: *Scope) void {
        self.entries.deinit(self.allocator);
    }

    /// Declares a variable binding in this scope.
    /// Returns `error.DuplicateDefinition` if `name` is already declared in
    /// the same (non-parent) scope.
    pub fn define(self: *Scope, name: []const u8, type_name: []const u8, is_mut: bool) !void {
        if (self.entries.contains(name)) {
            std.debug.print("Duplicate definition: {s}\n", .{name});
            return error.DuplicateDefinition;
        }

        const entry = ScopeEntry{
            .name = name,
            .type_name = type_name,
            .is_mut = is_mut,
            .is_function = false,
            .has_return = false,
        };
        try self.entries.put(self.allocator, name, entry);
    }

    /// Declares a function binding in this scope.
    /// Returns `error.DuplicateDefinition` if `name` is already declared.
    pub fn defineFunction(self: *Scope, name: []const u8, return_type: []const u8) !void {
        if (self.entries.contains(name)) return error.DuplicateDefinition;

        const entry = ScopeEntry{
            .name = name,
            .type_name = return_type,
            .is_mut = false,
            .is_function = true,
            .has_return = false,
        };
        try self.entries.put(self.allocator, name, entry);
    }

    /// Looks up `name` in this scope and all ancestor scopes.
    /// Returns `null` if the name is not declared anywhere in the chain.
    pub fn get(self: *const Scope, name: []const u8) ?ScopeEntry {
        if (self.entries.get(name)) |entry| return entry;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    /// Returns `true` if `name` is visible from this scope (including
    /// through the parent chain).
    pub fn exists(self: *const Scope, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Updates the type string of an existing binding named `name`.
    /// Walks the parent chain if the entry is not in the current scope.
    pub fn update(self: *Scope, name: []const u8, new_type: []const u8) !void {
        if (self.entries.getPtr(name)) |entry| {
            entry.type_name = new_type;
            return;
        }

        if (self.parent) |p| {
            try p.update(name, new_type);
        }
    }
};

/// Stack-based controller for lexical scopes.
///
/// Use `pushScope` when entering a block and `popScope` when leaving.
/// `getCurrentScope` returns the innermost active scope for symbol look-up.
pub const ScopeManager = struct {
    allocator: std.mem.Allocator,
    current_scope: ?*Scope,
    scope_stack: std.ArrayListUnmanaged(*Scope),

    /// Creates a `ScopeManager` with no active scope.
    pub fn init(allocator: std.mem.Allocator) ScopeManager {
        return .{
            .allocator = allocator,
            .current_scope = null,
            .scope_stack = .empty,
        };
    }

    /// Destroys all remaining scopes on the stack and frees the stack itself.
    pub fn deinit(self: *ScopeManager) void {
        for (self.scope_stack.items) |scope| {
            scope.deinit();
            self.allocator.destroy(scope);
        }
        self.scope_stack.deinit(self.allocator);
    }

    /// Allocates a new `Scope` whose parent is the current scope, pushes it
    /// onto the stack, and makes it the current scope.  Returns a pointer to
    /// the new scope.
    pub fn pushScope(self: *ScopeManager) !*Scope {
        const scope = try self.allocator.create(Scope);
        scope.* = Scope.init(self.allocator, self.current_scope);
        try self.scope_stack.append(self.allocator, scope);
        self.current_scope = scope;
        return scope;
    }

    /// Pops the innermost scope off the stack and restores the previous scope
    /// as current.  Does nothing if the stack is already empty.
    pub fn popScope(self: *ScopeManager) void {
        if (self.scope_stack.items.len > 0) {
            _ = self.scope_stack.pop();
            self.current_scope = if (self.scope_stack.items.len > 0)
                self.scope_stack.items[self.scope_stack.items.len - 1]
            else
                null;
        }
    }

    /// Returns the innermost currently active `Scope`, or `null` if no scope
    /// has been pushed yet.
    pub fn getCurrentScope(self: *ScopeManager) ?*Scope {
        return self.current_scope;
    }
};
