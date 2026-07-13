//! Model struct and database-collection code generator.
//!
//! `ModelGenerator` converts a `model_decl` AST node into:
//!   - A C `typedef struct` definition.
//!   - An `orbit_collection` initialiser that wires the model to its SQLite
//!     table (used by the Orbit DB runtime).

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

/// Generates a C struct definition and `orbit_collection` entry for one model.
pub const ModelGenerator = struct {
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    source: []const u8,

    /// Initialise a `ModelGenerator` that appends into `output`.
    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), source: []const u8) ModelGenerator {
        return .{
            .allocator = allocator,
            .output = output,
            .source = source,
        };
    }

    /// Emit a C struct definition and `orbit_collection` entry for the model AST `node`.
    pub fn generate(self: *ModelGenerator, node: *Node) !void {
        const model_data = node.data.model_decl;
        const model_name = model_data.name.getText(self.source);

        try self.output.appendSlice(self.allocator, "typedef struct {\n");

        for (model_data.fields) |field| {
            const field_data = field.data.field_decl;
            const field_name = field_data.name.getText(self.source);
            const field_type = field_data.type_name.getText(self.source);

            try self.output.appendSlice(self.allocator, "    ");
            try self.output.appendSlice(self.allocator, self.mapOrbitTypeToC(field_type));
            try self.output.append(self.allocator, ' ');
            try self.output.appendSlice(self.allocator, field_name);
            try self.output.appendSlice(self.allocator, ";\n");
        }

        try self.output.appendSlice(self.allocator, "} ");
        try self.output.appendSlice(self.allocator, model_name);
        try self.output.appendSlice(self.allocator, ";\n\n");

        try self.generateCollectionInit(model_name);
    }

    fn generateCollectionInit(self: *ModelGenerator, model_name: []const u8) !void {
        const table_name = try std.ascii.allocLowerString(self.allocator, model_name);
        defer self.allocator.free(table_name);

        try self.output.appendSlice(self.allocator, "orbit_collection ");
        try self.output.appendSlice(self.allocator, table_name);
        try self.output.appendSlice(self.allocator, "_collection = {\n");
        try self.output.appendSlice(self.allocator, "    .table_name = \"");
        try self.output.appendSlice(self.allocator, table_name);
        try self.output.appendSlice(self.allocator, "\",\n");
        try self.output.appendSlice(self.allocator, "    .schema = \"CREATE TABLE IF NOT EXISTS ");
        try self.output.appendSlice(self.allocator, table_name);
        try self.output.appendSlice(self.allocator, " (id TEXT PRIMARY KEY, JSON_DATA TEXT)\"\n");
        try self.output.appendSlice(self.allocator, "};\n\n");
    }

    fn mapOrbitTypeToC(self: *ModelGenerator, orbit_type: []const u8) []const u8 {
        _ = self;
        if (std.mem.eql(u8, orbit_type, "int")) return "orbit_int";
        if (std.mem.eql(u8, orbit_type, "float")) return "orbit_float";
        if (std.mem.eql(u8, orbit_type, "string")) return "orbit_string";
        if (std.mem.eql(u8, orbit_type, "bool")) return "orbit_bool";
        return "orbit_string";
    }
};
