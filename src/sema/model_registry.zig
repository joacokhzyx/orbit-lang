const std = @import("std");
const Token = @import("../token.zig").Token;

pub const ModelField = struct {
    name: []const u8,
    type_name: []const u8,
    is_primary: bool,
    is_unique: bool,
    is_auto: bool,
    decorators: []const []const u8,
};

pub const ModelInfo = struct {
    name: []const u8,
    fields: []const ModelField,
    table_name: []const u8,
};

pub const ModelRegistry = struct {
    models: std.StringHashMapUnmanaged(ModelInfo),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .models = .empty,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ModelRegistry) void {
        self.models.deinit(self.allocator);
    }
    
    pub fn register(self: *ModelRegistry, model: ModelInfo) !void {
        try self.models.put(self.allocator, model.name, model);
    }
    
    pub fn getModel(self: *const ModelRegistry, name: []const u8) ?ModelInfo {
        return self.models.get(name);
    }
    
    pub fn getField(self: *const ModelRegistry, model_name: []const u8, field_name: []const u8) ?ModelField {
        if (self.getModel(model_name)) |model| {
            for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return field;
                }
            }
        }
        return null;
    }
    
    pub fn hasModel(self: *const ModelRegistry, name: []const u8) bool {
        return self.models.contains(name);
    }
    
    pub fn getCollectionType(self: *const ModelRegistry, model_name: []const u8) []const u8 {
        if (self.hasModel(model_name)) {
            return "collection";
        }
        return "unknown";
    }
};
