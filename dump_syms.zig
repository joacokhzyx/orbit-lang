// Quick COFF symbol dump
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const path = "C:\\Users\\Alumnos\\AppData\\Local\\Temp\\orbit\\native_stub.obj";
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    defer alloc.free(data);

    if (data.len < 20) {
        std.debug.print("File too small\n", .{});
        return;
    }

    const num_syms = std.mem.readInt(u32, data[12..16], .little);
    const sym_table_off = std.mem.readInt(u32, data[8..12], .little);
    const str_table_off = sym_table_off + num_syms * 18;

    std.debug.print("SymTable offset=0x{x} count={d}\n", .{sym_table_off, num_syms});

    var i: u32 = 0;
    while (i < num_syms) : (i += 1) {
        const sym_off = sym_table_off + i * 18;
        if (sym_off + 18 > data.len) break;

        const name_bytes = data[sym_off..sym_off+8];
        var name: []const u8 = undefined;
        if (name_bytes[0] == 0 and name_bytes[1] == 0 and name_bytes[2] == 0 and name_bytes[3] == 0) {
            // String table reference
            const str_off = std.mem.readInt(u32, name_bytes[4..8], .little);
            const abs_off = str_table_off + str_off;
            if (abs_off < data.len) {
                var end = abs_off;
                while (end < data.len and data[end] != 0) end += 1;
                name = data[abs_off..end];
            } else name = "(invalid)";
        } else {
            // Inline name (up to 8 chars)
            var end: usize = 0;
            while (end < 8 and name_bytes[end] != 0) end += 1;
            name = name_bytes[0..end];
        }

        const sec_num = std.mem.readInt(i16, data[sym_off+12..sym_off+14], .little);
        const sym_class = data[sym_off+16];
        const aux_count = data[sym_off+17];

        if (std.mem.indexOf(u8, name, "Find") != null or
            std.mem.indexOf(u8, name, "__imp_Find") != null or
            std.mem.indexOf(u8, name, "chkstk") != null) {
            std.debug.print("  sym[{d}] '{s}' sec={d} class={d}\n", .{i, name, sec_num, sym_class});
        }

        i += aux_count;
    }
}
