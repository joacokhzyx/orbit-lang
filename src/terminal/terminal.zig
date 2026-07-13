//! Terminal façade for the Orbit compiler.
//! Re-exports the sub-modules (`capabilities`, `symbols`, `style`, `layout`)
//! and their most-used types under a single namespace, and provides the
//! top-level `init` helper that detects terminal capabilities and stores them
//! globally for the duration of the process.

const std = @import("std");

/// Sub-module: terminal capability detection.
pub const capabilities = @import("capabilities.zig");
/// Sub-module: Unicode/ASCII symbol catalogue.
pub const symbols = @import("symbols.zig");
/// Sub-module: ANSI colour-style helpers.
pub const style = @import("style.zig");
/// Sub-module: border, panel, and layout primitives.
pub const layout = @import("layout.zig");

/// Re-export: user-facing colour preference setting.
pub const ColorPreference = capabilities.ColorPreference;
/// Re-export: user-facing Unicode preference setting.
pub const UnicodePreference = capabilities.UnicodePreference;
/// Re-export: detected terminal capabilities record.
pub const TerminalCapabilities = capabilities.TerminalCapabilities;
/// Re-export: named symbol enum.
pub const Symbol = symbols.Symbol;
/// Re-export: named colour-style enum.
pub const Style = style.Style;

/// Detects terminal capabilities from the environment and stores them in a
/// process-wide global so that all rendering helpers can query them without
/// needing to thread the capabilities struct through every call.
///
/// `color_pref` and `unicode_pref` allow the caller to override automatic
/// detection.  `io` and `environ_map` are passed through to the underlying
/// platform checks.
pub fn init(color_pref: ColorPreference, unicode_pref: UnicodePreference, io: anytype, environ_map: anytype) TerminalCapabilities {
    return capabilities.init(color_pref, unicode_pref, io, environ_map);
}
