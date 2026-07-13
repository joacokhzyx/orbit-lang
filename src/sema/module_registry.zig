//! Standard-module registry for the Orbit semantic analyser.
//! Maintains a catalogue of built-in modules (e.g. `crypto`, `jwt`, `http`,
//! `file`, `server`) together with the function signatures they expose.
//! The type checker queries this registry to resolve member-access types on
//! module identifiers and validate call-site argument counts.

const std = @import("std");

/// A single parameter descriptor for a module function.
pub const ModuleParam = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Describes one function exported by a built-in module.
pub const ModuleFunction = struct {
    name: []const u8,
    params: []const ModuleParam,
    return_type: []const u8,
};

/// Represents a named collection of functions provided by a built-in module.
pub const Module = struct {
    name: []const u8,
    functions: []const ModuleFunction,
};

/// Registry that maps module names to their `Module` descriptors.
pub const ModuleRegistry = struct {
    modules: std.StringHashMapUnmanaged(Module),
    allocator: std.mem.Allocator,

    /// Creates an empty `ModuleRegistry` backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .modules = .empty,
            .allocator = allocator,
        };
    }

    /// Releases the internal hash map.
    pub fn deinit(self: *ModuleRegistry) void {
        self.modules.deinit(self.allocator);
    }

    /// Registers a module under `name` with the given function list.
    /// Overwrites any previous entry with the same name.
    pub fn register(self: *ModuleRegistry, name: []const u8, functions: []const ModuleFunction) !void {
        const module = Module{
            .name = name,
            .functions = functions,
        };
        try self.modules.put(self.allocator, name, module);
    }

    /// Looks up a module by name.  Returns `null` if not found.
    pub fn getModule(self: *ModuleRegistry, name: []const u8) ?Module {
        return self.modules.get(name);
    }

    /// Looks up a specific function within a module by module name and
    /// function name.  Returns `null` if either the module or the function
    /// is not found.
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

    /// Registers all Orbit built-in standard modules: `crypto`, `jwt`,
    /// `http`, `file`, and `server`.  Must be called once after `init`
    /// to make the standard library available during type checking.
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
