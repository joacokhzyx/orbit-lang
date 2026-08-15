//! orbit/src/backend/mir/model_layout.zig
//!
//! Computes the in-memory layout of Orbit models the same way the C backend
//! does, so the native backend can emit `mov [obj + offset], ...` /
//! `mov ..., [obj + offset]` for `load_field`/`store_field`.
//!
//! The C backend emits a plain `typedef struct { <c_type> <field>; ... } Name;`
//! (see `src/codegen/c_backend.zig` `generateModel`), so field offsets follow
//! the host C compiler's natural alignment rules. The type sizes/alignments in
//! this module mirror `mapFieldTypeToC` plus the runtime typedefs in
//! `src/runtime/types.c` (orbit_int = int, orbit_bool = bool, etc.).

const std = @import("std");
const ir_mod = @import("../../ir/ir.zig");
const IRModule = ir_mod.IRModule;

/// Precomputed model layout for one module.
pub const ModelLayout = struct {
    /// key = "ModelName.fieldName", value = byte offset from the struct start.
    field_offsets: std.StringHashMapUnmanaged(i32),
    /// field name -> owning model name, only when the name is unambiguous.
    field_owners: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *ModelLayout, allocator: std.mem.Allocator) void {
        var off_it = self.field_offsets.keyIterator();
        while (off_it.next()) |key| allocator.free(key.*);
        self.field_offsets.deinit(allocator);
        self.field_owners.deinit(allocator);
    }

    /// Resolves the byte offset of `field` in `model_name`, or null if the
    /// model/field pair is not present in the module.
    pub fn fieldOffset(self: *const ModelLayout, model_name: []const u8, field: []const u8) ?i32 {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ model_name, field }) catch return null;
        return self.field_offsets.get(key);
    }

    /// Computes the layout for every model in `ir_module`.
    pub fn compute(allocator: std.mem.Allocator, ir_module: *const IRModule) !ModelLayout {
        var field_offsets = std.StringHashMapUnmanaged(i32){};
        errdefer field_offsets.deinit(allocator);

        var field_owners = std.StringHashMapUnmanaged([]const u8){};
        errdefer field_owners.deinit(allocator);

        // Collect model / enum / union names to disambiguate uppercase types.
        var model_names = std.StringHashMapUnmanaged(void){};
        defer model_names.deinit(allocator);
        for (ir_module.models.items) |model| {
            try model_names.put(allocator, model.name, {});
        }

        var enum_names = std.StringHashMapUnmanaged(void){};
        defer enum_names.deinit(allocator);
        for (ir_module.types.items) |t| {
            if (t.kind == .enumeration) {
                try enum_names.put(allocator, t.name, {});
            }
        }

        for (ir_module.models.items) |model| {
            var offset: i32 = 0;
            for (model.fields.items) |field| {
                const field_align = alignOfFieldType(field.type_name, &model_names, &enum_names);
                offset = std.mem.alignForward(i32, offset, field_align);
                try field_offsets.put(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ model.name, field.name }), offset);
                offset += sizeOfFieldType(field.type_name, &model_names, &enum_names);
            }
        }

        // Build the global field-name -> owner map for unambiguous field names.
        var seen = std.StringHashMapUnmanaged([]const u8){};
        defer seen.deinit(allocator);
        for (ir_module.models.items) |model| {
            for (model.fields.items) |field| {
                if (seen.getPtr(field.name)) |existing| {
                    // Ambiguous across models: drop the owner entry.
                    if (!std.mem.eql(u8, existing.*, model.name)) {
                        _ = field_owners.remove(field.name);
                    }
                } else {
                    try seen.put(allocator, field.name, model.name);
                    try field_owners.put(allocator, field.name, model.name);
                }
            }
        }

        return .{ .field_offsets = field_offsets, .field_owners = field_owners };
    }
};

/// Size (bytes) of a field type as stored in a model struct.
fn sizeOfFieldType(type_name: []const u8, model_names: *const std.StringHashMapUnmanaged(void), enum_names: *const std.StringHashMapUnmanaged(void)) i32 {
    if (type_name.len > 0 and type_name[0] == '&') return 8; // pointer to T

    if (std.mem.eql(u8, type_name, "i8") or
        std.mem.eql(u8, type_name, "u8") or
        std.mem.eql(u8, type_name, "byte") or
        std.mem.eql(u8, type_name, "bool")) return 1;
    if (std.mem.eql(u8, type_name, "i16") or
        std.mem.eql(u8, type_name, "u16")) return 2;
    if (std.mem.eql(u8, type_name, "i32") or
        std.mem.eql(u8, type_name, "u32")) return 4;
    if (std.mem.eql(u8, type_name, "int")) return 4; // orbit_int
    if (model_names.contains(type_name)) return 8; // model pointer
    if (enum_names.contains(type_name)) return 4; // by-value enum (C default int)
    // 8-byte types: i64, u64, usize, isize, pointers, float, decimal, string,
    // response, validated string types, unions, aliases, and anything unknown.
    return 8;
}

/// Natural alignment (bytes) of a field type.
fn alignOfFieldType(type_name: []const u8, model_names: *const std.StringHashMapUnmanaged(void), enum_names: *const std.StringHashMapUnmanaged(void)) i32 {
    if (type_name.len > 0 and type_name[0] == '&') return 8;
    if (std.mem.eql(u8, type_name, "i8") or
        std.mem.eql(u8, type_name, "u8") or
        std.mem.eql(u8, type_name, "byte") or
        std.mem.eql(u8, type_name, "bool")) return 1;
    if (std.mem.eql(u8, type_name, "i16") or
        std.mem.eql(u8, type_name, "u16")) return 2;
    if (std.mem.eql(u8, type_name, "i32") or
        std.mem.eql(u8, type_name, "u32")) return 4;
    if (std.mem.eql(u8, type_name, "int")) return 4;
    if (model_names.contains(type_name)) return 8;
    if (enum_names.contains(type_name)) return 4;
    return 8;
}