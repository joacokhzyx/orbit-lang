//! Model registry for the Orbit semantic analyser.
//! Stores `ModelInfo` records (schema, field metadata, table name) for all
//! `model` declarations encountered during semantic analysis.  Provides
//! look-up helpers used by the type checker and IR builder to validate field
//! accesses and infer collection types.

const std = @import("std");
const Token = @import("../token.zig").Token;

/// Metadata for a single field within an Orbit model.
pub const ModelField = struct {
    name: []const u8,
    type_name: []const u8,
    is_primary: bool,
    is_unique: bool,
    is_auto: bool,
    decorators: []const []const u8,
};

/// Metadata for a complete model declaration, including its field list and
/// the backing database table name.
pub const ModelInfo = struct {
    name: []const u8,
    fields: []const ModelField,
    table_name: []const u8,
};

/// Global registry that maps model names to their `ModelInfo` descriptors.
pub const ModelRegistry = struct {
    models: std.StringHashMapUnmanaged(ModelInfo),
    allocator: std.mem.Allocator,

    /// Creates an empty `ModelRegistry` backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .models = .empty,
            .allocator = allocator,
        };
    }

    /// Releases the internal hash map.  The registry does not own the string
    /// or field slices stored inside `ModelInfo` values.
    pub fn deinit(self: *ModelRegistry) void {
        self.models.deinit(self.allocator);
    }

    /// Registers `model` in the registry, keyed by `model.name`.
    /// Overwrites any previous entry with the same name.
    pub fn register(self: *ModelRegistry, model: ModelInfo) !void {
        try self.models.put(self.allocator, model.name, model);
    }

    /// Looks up a model by name.  Returns `null` if no model with that name
    /// has been registered.
    pub fn getModel(self: *const ModelRegistry, name: []const u8) ?ModelInfo {
        return self.models.get(name);
    }

    /// Looks up a specific field within a model.  Returns `null` if either
    /// the model or the field is not found.
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

    /// Returns `true` if a model with the given name has been registered.
    pub fn hasModel(self: *const ModelRegistry, name: []const u8) bool {
        return self.models.contains(name);
    }

    /// Returns the Orbit type string for a model's collection accessor.
    /// Returns `"collection"` for known models and `"unknown"` otherwise.
    pub fn getCollectionType(self: *const ModelRegistry, model_name: []const u8) []const u8 {
        if (self.hasModel(model_name)) {
            return "collection";
        }
        return "unknown";
    }
};
