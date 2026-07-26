const std = @import("std");

pub fn mapOrbitTypeToC(orbit_type: []const u8) []const u8 {
    if (std.mem.eql(u8, orbit_type, "int")) return "orbit_int";
    if (std.mem.eql(u8, orbit_type, "float")) return "orbit_float";
    if (std.mem.eql(u8, orbit_type, "string")) return "orbit_string";
    if (std.mem.eql(u8, orbit_type, "bool")) return "orbit_bool";
    if (std.mem.eql(u8, orbit_type, "void")) return "void";
    if (std.mem.eql(u8, orbit_type, "decimal")) return "double";
    if (std.mem.eql(u8, orbit_type, "Email") or
        std.mem.eql(u8, orbit_type, "URL") or
        std.mem.eql(u8, orbit_type, "UUID") or
        std.mem.eql(u8, orbit_type, "Phone") or
        std.mem.eql(u8, orbit_type, "IP")) return "orbit_string";
    if (std.mem.eql(u8, orbit_type, "Date") or
        std.mem.eql(u8, orbit_type, "Time") or
        std.mem.eql(u8, orbit_type, "DateTime") or
        std.mem.eql(u8, orbit_type, "Timestamp")) return "orbit_string";
    return "orbit_string";
}
