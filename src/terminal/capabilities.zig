//! Terminal capability detection for the Orbit compiler's output layer.
//! Probes the running process's stdout/stderr to determine whether ANSI
//! colour codes and Unicode characters should be emitted.  Results are
//! stored in a process-wide global (`global_caps`) so that all rendering
//! helpers can query them without extra plumbing.

const std = @import("std");
const builtin = @import("builtin");

/// Controls whether ANSI colour escape sequences are used in output.
pub const ColorPreference = enum {
    /// Detect automatically from environment variables and TTY state.
    auto,
    /// Always emit colour codes regardless of TTY state.
    always,
    /// Never emit colour codes.
    never,
};

/// Controls whether Unicode box-drawing / symbol characters are used in output.
pub const UnicodePreference = enum {
    /// Detect automatically from the `LANG` environment variable or OS defaults.
    auto,
    /// Always use Unicode characters.
    always,
    /// Fall back to plain ASCII.
    never,
};

/// Detected capabilities for the current terminal session.
pub const TerminalCapabilities = struct {
    has_color: bool,
    has_unicode: bool,
    is_stdout_tty: bool,
    is_stderr_tty: bool,
};

var global_caps: ?TerminalCapabilities = null;

/// Detects terminal capabilities and writes them to the process-wide global.
///
/// On Windows, enables Virtual Terminal Processing (ANSI support) when stdout
/// is a console handle.  The `NO_COLOR` and `TERM=dumb` conventions are
/// honoured in `auto` colour mode.  Unicode detection falls back to
/// `LANG` inspection on POSIX and defaults to `true` on Windows.
pub fn init(color_pref: ColorPreference, unicode_pref: UnicodePreference, io: anytype, environ_map: anytype) TerminalCapabilities {
    _ = io;
    const is_stdout = checkStdoutTty();
    const is_stderr = checkStderrTty();

    // Enable VT processing on Windows
    if (builtin.os.tag == .windows and is_stdout) {
        enableWindowsVT();
    }

    var color = false;
    switch (color_pref) {
        .always => color = true,
        .never => color = false,
        .auto => {
            const no_color_env = environ_map.get("NO_COLOR");
            const term_env = environ_map.get("TERM");
            const is_dumb = if (term_env) |t| std.mem.eql(u8, t, "dumb") else false;

            if (no_color_env != null or is_dumb) {
                color = false;
            } else {
                color = is_stdout;
            }
        },
    }

    var unicode = false;
    switch (unicode_pref) {
        .always => unicode = true,
        .never => unicode = false,
        .auto => {
            // Check if encoding is UTF-8 or terminal supports unicode
            const lang = environ_map.get("LANG") orelse "";
            const is_utf8 = std.mem.indexOf(u8, lang, "UTF-8") != null or std.mem.indexOf(u8, lang, "utf8") != null;

            if (builtin.os.tag == .windows) {
                const is_wt = environ_map.get("WT_SESSION") != null;
                unicode = is_wt or isWindowsUtf8();
            } else {
                unicode = is_utf8 or (environ_map.get("TERM") != null and !std.mem.eql(u8, environ_map.get("TERM").?, "dumb"));
            }
        },
    }

    const caps = TerminalCapabilities{
        .has_color = color,
        .has_unicode = unicode,
        .is_stdout_tty = is_stdout,
        .is_stderr_tty = is_stderr,
    };
    global_caps = caps;
    return caps;
}

/// Returns the globally stored `TerminalCapabilities`.  If `init` has not
/// been called yet, returns a safe all-false default (no colour, no Unicode,
/// no TTY).
pub fn get() TerminalCapabilities {
    return global_caps orelse .{
        .has_color = false,
        .has_unicode = false,
        .is_stdout_tty = false,
        .is_stderr_tty = false,
    };
}

const win32_k32 = struct {
    pub const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
    pub const STD_OUTPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -11));
    pub const STD_ERROR_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -12));

    pub extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
    pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: std.os.windows.UINT) callconv(.winapi) c_int;
    pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) std.os.windows.UINT;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) c_int;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) c_int;
};

fn isWindowsUtf8() bool {
    if (builtin.os.tag != .windows) return true;
    _ = win32_k32.SetConsoleOutputCP(65001);
    return win32_k32.GetConsoleOutputCP() == 65001;
}

fn checkStdoutTty() bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const raw_handle = win32_k32.GetStdHandle(win32_k32.STD_OUTPUT_HANDLE);
        if (raw_handle) |handle| {
            if (handle == windows.INVALID_HANDLE_VALUE) return false;
            var mode: windows.DWORD = 0;
            return win32_k32.GetConsoleMode(handle, &mode) != 0;
        } else {
            return false;
        }
    } else {
        if (std.posix.tcgetattr(std.posix.STDOUT_FILENO)) |_| {
            return true;
        } else |_| {
            return false;
        }
    }
}

fn checkStderrTty() bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const raw_handle = win32_k32.GetStdHandle(win32_k32.STD_ERROR_HANDLE);
        if (raw_handle) |handle| {
            if (handle == windows.INVALID_HANDLE_VALUE) return false;
            var mode: windows.DWORD = 0;
            return win32_k32.GetConsoleMode(handle, &mode) != 0;
        } else {
            return false;
        }
    } else {
        if (std.posix.tcgetattr(std.posix.STDERR_FILENO)) |_| {
            return true;
        } else |_| {
            return false;
        }
    }
}

fn enableWindowsVT() void {
    _ = win32_k32.SetConsoleOutputCP(65001);
    enableVTOnHandle(win32_k32.STD_OUTPUT_HANDLE);
    enableVTOnHandle(win32_k32.STD_ERROR_HANDLE);
}

/// Enables ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004) and
/// ENABLE_PROCESSED_OUTPUT (0x0001) on the given standard handle so that
/// ANSI escape sequences (colors, cursor movement) and UTF-8 braille frames
/// render correctly when writing raw bytes via WriteFile.
fn enableVTOnHandle(std_handle: std.os.windows.DWORD) void {
    const windows = std.os.windows;
    const raw = win32_k32.GetStdHandle(std_handle);
    if (raw) |h| {
        if (h == windows.INVALID_HANDLE_VALUE) return;
        var mode: windows.DWORD = 0;
        if (win32_k32.GetConsoleMode(h, &mode) != 0) {
            mode |= 0x0001; // ENABLE_PROCESSED_OUTPUT
            mode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
            _ = win32_k32.SetConsoleMode(h, mode);
        }
    }
}
