//! Orbit Core Line & Token-Aware Formatter
//! Preserves comments, normalizes indentation ({}), cleans trailing whitespace, and formats spacing.

const std = @import("std");
const rules = @import("rules.zig");

pub fn formatSource(allocator: std.mem.Allocator, source: []const u8, options: rules.FormatterOptions) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var indent_level: usize = 0;
    var consecutive_empty_lines: usize = 0;

    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        // Handle empty lines (allow 1 empty line, collapse 2+)
        if (trimmed.len == 0) {
            consecutive_empty_lines += 1;
            if (consecutive_empty_lines <= 1) {
                try out.append(allocator, '\n');
            }
            continue;
        }

        consecutive_empty_lines = 0;

        // Dedent line if it starts with a closing brace/bracket
        if (trimmed.len > 0 and (trimmed[0] == '}' or trimmed[0] == ']')) {
            if (indent_level > 0) indent_level -= 1;
        }

        // Apply indentation spaces
        var i: usize = 0;
        while (i < indent_level * options.indent_size) : (i += 1) {
            try out.append(allocator, ' ');
        }

        // Process line content with normalized spacing
        const formatted_line = try formatLineSpacing(allocator, trimmed);
        defer allocator.free(formatted_line);

        try out.appendSlice(allocator, formatted_line);
        try out.append(allocator, '\n');

        // Adjust indentation for opening braces on this line (excluding comments & string literals)
        const comment_idx = std.mem.indexOf(u8, trimmed, "//") orelse trimmed.len;
        const code_part = trimmed[0..comment_idx];

        for (code_part) |ch| {
            if (ch == '{' or ch == '[') {
                indent_level += 1;
            } else if (ch == '}' or ch == ']') {
                if (trimmed[0] != '}' and trimmed[0] != ']' and indent_level > 0) {
                    indent_level -= 1;
                }
            }
        }
    }

    if (options.insert_final_newline and (out.items.len == 0 or out.items[out.items.len - 1] != '\n')) {
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn formatLineSpacing(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    // If line is a pure comment, preserve as-is
    if (std.mem.startsWith(u8, line, "//")) {
        return try allocator.dupe(u8, line);
    }

    var result = std.ArrayListUnmanaged(u8).empty;
    defer result.deinit(allocator);

    var in_string = false;
    var string_char: u8 = 0;

    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) {
        const c = line[idx];

        // Comment check
        if (!in_string and c == '/' and idx + 1 < line.len and line[idx + 1] == '/') {
            try result.appendSlice(allocator, line[idx..]);
            break;
        }

        // String tracking
        if (c == '"' or c == '\'') {
            if (!in_string) {
                in_string = true;
                string_char = c;
            } else if (c == string_char and (idx == 0 or line[idx - 1] != '\\')) {
                in_string = false;
            }
        }

        if (in_string) {
            try result.append(allocator, c);
            continue;
        }

        // Normalize colon spacing (key: val)
        if (c == ':') {
            try result.append(allocator, ':');
            if (idx + 1 < line.len and line[idx + 1] != ' ' and line[idx + 1] != ':') {
                try result.append(allocator, ' ');
            }
            continue;
        }

        // Normalize comma spacing
        if (c == ',') {
            try result.append(allocator, ',');
            if (idx + 1 < line.len and line[idx + 1] != ' ') {
                try result.append(allocator, ' ');
            }
            continue;
        }

        try result.append(allocator, c);
    }

    return try result.toOwnedSlice(allocator);
}
