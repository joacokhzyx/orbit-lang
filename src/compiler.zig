const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const ast = @import("ast.zig");
const Node = ast.Node;

pub const CompilationUnit = struct {
    file_path: []const u8,
    source: []const u8,
    root: *Node,
};

pub const CompilationError = error{
    FileNotFound,
    ParseError,
    SemanticError,
    CircularImport,
    OutOfMemory,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayListUnmanaged(CompilationUnit),
    seen: std.StringHashMapUnmanaged(void),

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .units = .empty,
            .seen = .empty,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.units.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }

    pub fn loadEntry(self: *Compiler, io: anytype, entry_path: []const u8) !void {
        try self.loadFile(io, entry_path, null);
    }

    fn loadFile(self: *Compiler, io: anytype, file_path: []const u8, from_path: ?[]const u8) anyerror!void {
        if (self.seen.contains(file_path)) return;

        const owned_path = try self.allocator.dupe(u8, file_path);
        try self.seen.put(self.allocator, owned_path, {});

        const source = readFileAlloc(self.allocator, io, file_path) catch |err| {
            std.debug.print("orbit: cannot open '{s}': {s}\n", .{ file_path, @errorName(err) });
            if (from_path) |fp| std.debug.print("  imported from: {s}\n", .{fp});
            return CompilationError.FileNotFound;
        };

        var parser = Parser.init(source, file_path, self.allocator);
        const root = parser.parse() catch |err| {
            const tok = parser.current_token;
            const path = if (tok.file_path.len > 0) tok.file_path else file_path;
            std.debug.print("\n ⏣ Orbit  parse error\n\n  [SYNTAX ERROR] unexpectedly found '{s}'\n  file: {s}:{d}\n\n",
                .{ @tagName(tok.tag), path, tok.loc.line });
            return err;
        };

        try self.units.append(self.allocator, .{
            .file_path = owned_path,
            .source = source,
            .root = root,
        });

        for (root.data.root.decls) |decl| {
            if (decl.tag == .import_stmt) {
                const import_path_raw = decl.data.import_stmt.path.text;
                const import_path = stripQuotes(import_path_raw);
                const resolved = try resolveImportPath(self.allocator, file_path, import_path);
                try self.loadFile(io, resolved, file_path);
            }
        }
    }

    pub fn mergedSource(self: *Compiler) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        for (self.units.items) |unit| {
            try buf.appendSlice(self.allocator, unit.source);
            try buf.append(self.allocator, '\n');
        }
        return buf.toOwnedSlice(self.allocator);
    }

    pub fn mergedRoots(self: *Compiler) !*Node {
        if (self.units.items.len == 0) return CompilationError.FileNotFound;
        if (self.units.items.len == 1) return self.units.items[0].root;

        var all_decls = std.ArrayListUnmanaged(*Node).empty;
        for (self.units.items) |unit| {
            for (unit.root.data.root.decls) |decl| {
                if (decl.tag != .import_stmt) {
                    try all_decls.append(self.allocator, decl);
                }
            }
        }

        const merged = try self.allocator.create(Node);
        merged.* = .{
            .tag = .root,
            .data = .{ .root = .{
                .decls = try all_decls.toOwnedSlice(self.allocator),
            }},
        };
        return merged;
    }
};

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1..s.len-1];
    }
    return s;
}

fn resolveImportPath(allocator: std.mem.Allocator, from_path: []const u8, import_path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, import_path, "/") or
        (import_path.len > 1 and import_path[1] == ':'))
    {
        return try allocator.dupe(u8, import_path);
    }

    var base_dir = pathDirName(from_path);
    var rel = import_path;

    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    while (std.mem.startsWith(u8, rel, "../")) {
        rel = rel[3..];
        base_dir = pathDirName(base_dir);
    }

    if (base_dir.len == 0) return try allocator.dupe(u8, rel);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, rel });
}

fn pathDirName(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[0..i];
    }
    return "";
}

fn readFileAlloc(allocator: std.mem.Allocator, io: anytype, file_path: []const u8) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    const source = try allocator.alloc(u8, file_len);

    var read_buffer: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &read_buffer);
    try reader.interface.readSliceAll(source);

    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        return source[3..];
    }
    return source;
}
