const std = @import("std");
const builtin = @import("builtin");

pub const ColorPreference = enum {
    auto,
    always,
    never,
};

pub const UnicodePreference = enum {
    auto,
    always,
    never,
};

pub const TerminalCapabilities = struct {
    has_color: bool,
    has_unicode: bool,
    is_stdout_tty: bool,
    is_stderr_tty: bool,
};

var global_caps: ?TerminalCapabilities = null;

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
                // Windows supports unicode by default in modern terminals or if code page is UTF-8
                unicode = true; 
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

pub fn get() TerminalCapabilities {
    return global_caps orelse .{
        .has_color = false,
        .has_unicode = false,
        .is_stdout_tty = false,
        .is_stderr_tty = false,
    };
}

fn checkStdoutTty() bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const raw_handle = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE);
        if (raw_handle) |handle| {
            if (handle == windows.INVALID_HANDLE_VALUE) return false;
            var mode: windows.DWORD = 0;
            return windows.kernel32.GetConsoleMode(handle, &mode) != 0;
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
        const raw_handle = windows.kernel32.GetStdHandle(windows.STD_ERROR_HANDLE);
        if (raw_handle) |handle| {
            if (handle == windows.INVALID_HANDLE_VALUE) return false;
            var mode: windows.DWORD = 0;
            return windows.kernel32.GetConsoleMode(handle, &mode) != 0;
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
    const windows = std.os.windows;
    const raw_handle = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    if (raw_handle) |handle| {
        if (handle != windows.INVALID_HANDLE_VALUE) {
            var mode: windows.DWORD = 0;
            if (windows.kernel32.GetConsoleMode(handle, &mode) != 0) {
                mode |= 0x0004; // ENABLE_VIRTUAL_TERMINAL_PROCESSING
                _ = windows.kernel32.SetConsoleMode(handle, mode);
            }
        }
    }
}
