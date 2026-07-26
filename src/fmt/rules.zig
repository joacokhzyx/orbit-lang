//! Orbit Formatter Rules & Configuration
//! Handles indentation levels, spacing, and formatting style options.

const std = @import("std");

pub const FormatterOptions = struct {
    indent_size: usize = 4,
    use_spaces: bool = true,
    max_line_width: usize = 100,
    trim_trailing_whitespace: bool = true,
    insert_final_newline: bool = true,
    space_after_colon: bool = true,
    space_around_operators: bool = true,

    check_only: bool = false,
    show_diff: bool = false,
    write_in_place: bool = true,
};

pub const IndentStyle = struct {
    level: usize = 0,
    size: usize = 4,

    pub fn indent(self: *IndentStyle) void {
        self.level += 1;
    }

    pub fn dedent(self: *IndentStyle) void {
        if (self.level > 0) self.level -= 1;
    }

    pub fn write(self: IndentStyle, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.level * self.size) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
};
