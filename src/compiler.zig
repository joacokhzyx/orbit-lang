//! Multi-file compilation driver for the Orbit language.
//!
//! `Compiler` orchestrates loading, parsing, and linking of one or more Orbit
//! source files.  It resolves `import` statements recursively, detects circular
//! imports, and ultimately produces a merged AST root and a concatenated source
//! string that downstream phases (semantic analysis, code generation) can
//! consume as a single compilation unit.

const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const ast = @import("ast.zig");
const Node = ast.Node;

// ─── Types ────────────────────────────────────────────────────────────────────

/// A successfully parsed source file together with its AST root.
pub const CompilationUnit = struct {
    file_path: []const u8,
    source: []const u8,
    root: *Node,
};

/// Errors that may be returned by `Compiler` operations.
pub const CompilationError = error{
    FileNotFound,
    ParseError,
    SemanticError,
    CircularImport,
    OutOfMemory,
};

// ─── Compiler ─────────────────────────────────────────────────────────────────

/// Drives the loading and parsing of an Orbit project.
///
/// `Compiler` maintains a set of already-visited file paths to prevent
/// duplicate processing and circular imports.  After all files have been
/// loaded, callers can retrieve the merged AST via `mergedRoots` or the
/// concatenated source via `mergedSource`.
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayListUnmanaged(CompilationUnit),
    seen: std.StringHashMapUnmanaged(void),

    /// Creates an empty `Compiler` backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .units = .empty,
            .seen = .empty,
        };
    }

    /// Releases all memory owned by the `Compiler` (unit list and seen-set).
    /// Does **not** free the parsed AST nodes — those are owned by each
    /// compilation unit's arena.
    pub fn deinit(self: *Compiler) void {
        self.units.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }

    /// Loads and parses the project entry-point file at `entry_path`,
    /// recursively following all `import` declarations.
    pub fn loadEntry(self: *Compiler, io: anytype, entry_path: []const u8) !void {
        try self.loadFile(io, entry_path, null);
    }

    /// Internal recursive loader.  `from_path` is the path of the file that
    /// triggered this import (used only for error messages).
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

            var cur_line: usize = 1;
            var line_start: usize = 0;
            var line_end: usize = source.len;
            for (source, 0..) |c, idx| {
                if (cur_line == tok.loc.line) {
                    if (c == '\n') {
                        line_end = idx;
                        break;
                    }
                } else if (c == '\n') {
                    cur_line += 1;
                    line_start = idx + 1;
                }
            }
            if (line_start > source.len) line_start = 0;
            if (line_end > source.len or line_end < line_start) line_end = source.len;
            const src_line = std.mem.trim(u8, source[line_start..line_end], "\r\n");

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "unexpected token '{s}'", .{@tagName(tok.tag)}) catch "syntax error";

            const term = @import("terminal/layout.zig");
            term.renderErrorCardStderr("E0301", msg, path, tok.loc.line, tok.loc.col, src_line, "Check for missing brackets, quotes, or keywords before this token.", 68);
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

    /// Returns a heap-allocated buffer containing the concatenated source text
    /// of all loaded compilation units, separated by newlines.
    /// The caller owns the returned slice.
    pub fn mergedSource(self: *Compiler) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        for (self.units.items) |unit| {
            try buf.appendSlice(self.allocator, unit.source);
            try buf.append(self.allocator, '\n');
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Returns a single `Node.root` whose `decls` slice is the union of all
    /// top-level declarations across every loaded file (import statements are
    /// excluded from the merged output).
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
            } },
        };
        return merged;
    }
};

// ─── File / path utilities ────────────────────────────────────────────────────

/// Strips surrounding double-quote characters from `s`, if present.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Resolves `import_path` relative to the directory of `from_path`.
/// Absolute paths (Unix `/` prefix or Windows drive letter) are returned as-is.
/// Leading `./` and `../` sequences are normalised.
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

/// Returns the directory component of `path` (everything before the last
/// `/` or `\`), or an empty slice if `path` contains no separator.
fn pathDirName(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[0..i];
    }
    return "";
}

/// Reads the entire contents of `file_path` into a freshly allocated buffer.
/// Strips a UTF-8 BOM (`EF BB BF`) if one is present at the start of the file.
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
