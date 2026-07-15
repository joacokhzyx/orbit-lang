//! orbit/src/backend/diagnostics.zig
//!
//! Standardised error messages for the Native backend.
//! Every unsupported-feature diagnostic follows the ORB-NATIVE-UNSUPPORTED format
//! so that tooling can parse and react to them reliably.

const std = @import("std");

/// Emit a clear, machine-parseable diagnostic when the native backend cannot
/// handle a given IR feature.
///
/// Format:
///   ORB-NATIVE-UNSUPPORTED:
///   Native backend does not yet support `<feature>`.
///   Use `--backend=steel` or remove the unsupported operation.
pub fn unsupportedFeature(feature: []const u8) void {
    std.debug.print(
        \\
        \\ORB-NATIVE-UNSUPPORTED:
        \\Native backend does not yet support `{s}`.
        \\Use `--backend=steel` or remove the unsupported operation.
        \\
    , .{feature});
}

/// Log that the --backend=auto mode fell back to Steel for a specific reason.
pub fn autoFallback(reason: []const u8) void {
    std.debug.print(
        "[backend:auto] falling back to Steel: {s}\n",
        .{reason},
    );
}
