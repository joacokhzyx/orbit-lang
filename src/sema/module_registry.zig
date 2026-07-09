const std = @import("std");

pub const ModuleParam = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const ModuleFunction = struct {
    name: []const u8,
    params: []const ModuleParam,
    return_type: []const u8,
};

pub const Module = struct {
    name: []const u8,
    functions: []const ModuleFunction,
};

pub const ModuleRegistry = struct {
    modules: std.StringHashMapUnmanaged(Module),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .modules = .empty,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ModuleRegistry) void {
        self.modules.deinit(self.allocator);
    }
    
    pub fn register(self: *ModuleRegistry, name: []const u8, functions: []const ModuleFunction) !void {
        const module = Module{
            .name = name,
            .functions = functions,
        };
        try self.modules.put(self.allocator, name, module);
    }
    
    pub fn getModule(self: *ModuleRegistry, name: []const u8) ?Module {
        return self.modules.get(name);
    }
    
    pub fn getFunction(self: *ModuleRegistry, module_name: []const u8, func_name: []const u8) ?ModuleFunction {
        if (self.getModule(module_name)) |module| {
            for (module.functions) |func| {
                if (std.mem.eql(u8, func.name, func_name)) {
                    return func;
                }
            }
        }
        return null;
    }
    
    pub fn initStandardModules(self: *ModuleRegistry) !void {
        try self.register("crypto", &[_]ModuleFunction{
            .{
                .name = "bcrypt",
                .params = &[_]ModuleParam{.{ .name = "password", .type_name = "string" }},
                .return_type = "string",
            },
            .{
                .name = "verify",
                .params = &[_]ModuleParam{
                    .{ .name = "password", .type_name = "string" },
                    .{ .name = "hash", .type_name = "string" },
                },
                .return_type = "bool",
            },
        });
        
        try self.register("jwt", &[_]ModuleFunction{
            .{
                .name = "sign",
                .params = &[_]ModuleParam{.{ .name = "payload", .type_name = "object" }},
                .return_type = "string",
            },
            .{
                .name = "verify",
                .params = &[_]ModuleParam{.{ .name = "token", .type_name = "string" }},
                .return_type = "object",
            },
        });
        
        try self.register("http", &[_]ModuleFunction{
            .{
                .name = "get",
                .params = &[_]ModuleParam{.{ .name = "url", .type_name = "string" }},
                .return_type = "object",
            },
            .{
                .name = "post",
                .params = &[_]ModuleParam{
                    .{ .name = "url", .type_name = "string" },
                    .{ .name = "body", .type_name = "object" },
                },
                .return_type = "object",
            },
        });
        
        try self.register("file", &[_]ModuleFunction{
            .{
                .name = "read",
                .params = &[_]ModuleParam{.{ .name = "path", .type_name = "string" }},
                .return_type = "string",
            },
            .{
                .name = "write",
                .params = &[_]ModuleParam{
                    .{ .name = "path", .type_name = "string" },
                    .{ .name = "content", .type_name = "string" },
                },
                .return_type = "bool",
            },
        });
        
        try self.register("server", &[_]ModuleFunction{
            .{
                .name = "listen",
                .params = &[_]ModuleParam{.{ .name = "port", .type_name = "int" }},
                .return_type = "bool",
            },
        });
    }
};
