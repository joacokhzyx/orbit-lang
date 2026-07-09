const std = @import("std");

pub const ScopeEntry = struct {
    name: []const u8,
    type_name: []const u8,
    is_mut: bool,
    is_function: bool,
    has_return: bool,
};

pub const Scope = struct {
    entries: std.StringHashMapUnmanaged(ScopeEntry),
    parent: ?*Scope,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .entries = .{},
            .parent = parent,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Scope) void {
        self.entries.deinit(self.allocator);
    }
    
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
    
    pub fn get(self: *const Scope, name: []const u8) ?ScopeEntry {
        if (self.entries.get(name)) |entry| return entry;
        if (self.parent) |p| return p.get(name);
        return null;
    }
    
    pub fn exists(self: *const Scope, name: []const u8) bool {
        return self.get(name) != null;
    }
    
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

pub const ScopeManager = struct {
    allocator: std.mem.Allocator,
    current_scope: ?*Scope,
    scope_stack: std.ArrayListUnmanaged(*Scope),
    
    pub fn init(allocator: std.mem.Allocator) ScopeManager {
        return .{
            .allocator = allocator,
            .current_scope = null,
            .scope_stack = .{},
        };
    }
    
    pub fn deinit(self: *ScopeManager) void {
        for (self.scope_stack.items) |scope| {
            scope.deinit();
            self.allocator.destroy(scope);
        }
        self.scope_stack.deinit(self.allocator);
    }
    
    pub fn pushScope(self: *ScopeManager) !*Scope {
        const scope = try self.allocator.create(Scope);
        scope.* = Scope.init(self.allocator, self.current_scope);
        try self.scope_stack.append(self.allocator, scope);
        self.current_scope = scope;
        return scope;
    }
    
    pub fn popScope(self: *ScopeManager) void {
        if (self.scope_stack.items.len > 0) {
            _ = self.scope_stack.pop();
            self.current_scope = if (self.scope_stack.items.len > 0)
                self.scope_stack.items[self.scope_stack.items.len - 1]
            else
                null;
        }
    }
    
    pub fn getCurrentScope(self: *ScopeManager) ?*Scope {
        return self.current_scope;
    }
};
