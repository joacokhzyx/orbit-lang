const std = @import("std");

pub const capabilities = @import("capabilities.zig");
pub const symbols = @import("symbols.zig");
pub const style = @import("style.zig");
pub const layout = @import("layout.zig");

pub const ColorPreference = capabilities.ColorPreference;
pub const UnicodePreference = capabilities.UnicodePreference;
pub const TerminalCapabilities = capabilities.TerminalCapabilities;
pub const Symbol = symbols.Symbol;
pub const Style = style.Style;

pub fn init(color_pref: ColorPreference, unicode_pref: UnicodePreference, io: anytype, environ_map: anytype) TerminalCapabilities {
    return capabilities.init(color_pref, unicode_pref, io, environ_map);
}
