//! orbit/src/backend/link/mod.zig
//!
//! Entrypoint for the neutral object writing and native linking API.

const std = @import("std");
pub const object = @import("object.zig");
pub const reloc = @import("reloc.zig");
pub const elf_writer = @import("elf_writer.zig");
pub const coff_writer = @import("coff_writer.zig");
pub const elf_reader = @import("elf_reader.zig");
pub const coff_reader = @import("coff_reader.zig");
pub const archive = @import("archive.zig");
pub const linker = @import("linker.zig");
pub const layout = @import("layout.zig");

pub const pe_image = @import("pe_image.zig");
pub const elf_image = @import("elf_image.zig");

pub const Format = enum {
    coff,
    elf,
};

pub fn writeObject(allocator: std.mem.Allocator, format: Format, obj: *const object.Object) ![]const u8 {
    return switch (format) {
        .coff => coff_writer.writeObject(allocator, obj),
        .elf => elf_writer.writeObject(allocator, obj),
    };
}

fn readFile(allocator: std.mem.Allocator, io: anytype, path_str: []const u8) ![]const u8 {
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path_str, .{});
    defer file.close(io);

    const len = try file.length(io);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    var read_buf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &read_buf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

fn writeFile(io: anytype, path_str: []const u8, bytes: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path_str, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &write_buf);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}

pub fn link(
    allocator: std.mem.Allocator,
    io: anytype,
    format: Format,
    output_path: []const u8,
    object_paths: []const []const u8,
    archive_paths: []const []const u8,
    entry_name: []const u8,
) !void {
    var lnk = linker.Linker.init(allocator);
    defer lnk.deinit();

    var buffers = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (buffers.items) |buf| {
            allocator.free(buf);
        }
        buffers.deinit(allocator);
    }

    // Load objects
    for (object_paths) |op| {
        const bytes = try readFile(allocator, io, op);
        try buffers.append(allocator, bytes);

        const obj = try switch (format) {
            .coff => coff_reader.readObject(allocator, bytes),
            .elf => elf_reader.readObject(allocator, bytes),
        };
        try lnk.addObject(op, obj);
    }

    // Load archives
    for (archive_paths) |ap| {
        const bytes = readFile(allocator, io, ap) catch continue;
        try buffers.append(allocator, bytes);

        const ar = try archive.parseArchive(allocator, bytes);
        try lnk.addArchive(ar);
    }

    // Resolve symbols and merge sections
    try lnk.resolveSymbols();
    try lnk.mergeSections();

    // Write final executable
    const exe_bytes = try switch (format) {
        .coff => pe_image.writeExecutable(allocator, &lnk, entry_name),
        .elf => elf_image.writeExecutable(allocator, &lnk, entry_name),
    };
    defer allocator.free(exe_bytes);

    try writeFile(io, output_path, exe_bytes);
}
