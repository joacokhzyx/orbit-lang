const std = @import("std");

pub const AtlasConfig = struct {
    // ── Project Identity ────────────────────────────────────────────
    project: []const u8 = "orbit-app",
    version: []const u8 = "0.1.0",

    // ── Server ──────────────────────────────────────────────────────
    port: u16 = 3000,
    worker_threads: u32 = 0,         // 0 = auto-detect CPU count
    keepalive_timeout_s: u32 = 30,
    keepalive_max_requests: u32 = 1000,

    // ── Database ────────────────────────────────────────────────────────────
    db_path: []const u8 = "orbit.db",

    // ── Arena ────────────────────────────────────────────────────────────────
    arena_pool_size: u32 = 128,       // per-pool slots (pool is now backup-only)
    arena_default_capacity: u32 = 65536,

    // ── String Pool ─────────────────────────────────────────────────
    string_pool_capacity: u32 = 4096,

    // ── Kynx Security ───────────────────────────────────────────────
    no_kynx: bool = false,
    kynx_pool_size: u32 = 1024,
    kynx_rate_limit: u32 = 100,
    kynx_window_ms: u32 = 1000,
    kynx_ban_threshold: u32 = 500,

    // ── Developer ───────────────────────────────────────────────────
    pulse_active: bool = true,
    pulse_rate: u32 = 1000,
    logs_active: bool = true,

    // ── Build ───────────────────────────────────────────────────────
    output_name: []const u8 = "orbit_app",
    cache: bool = true,

    pub fn load(allocator: std.mem.Allocator, io: anytype) !AtlasConfig {
        var config = AtlasConfig{};
        const file_path = "orbit.atlas";
        
        var cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, file_path, .{}) catch {
            return config;
        };
        defer file.close(io);

        const file_len = file.length(io) catch return config;
        const content = try allocator.alloc(u8, file_len);
        defer allocator.free(content);

        var read_buffer: [8192]u8 = undefined;
        var file_reader_state = std.Io.File.Reader.init(file, io, &read_buffer);
        file_reader_state.interface.readSliceAll(content) catch return config;

        // ── Parse key-value pairs ────────────────────────────────────
        if (extractValue(content, "project:")) |val| {
            config.project = try allocator.dupe(u8, val);
        }
        
        if (extractValue(content, "version:")) |val| {
            config.version = try allocator.dupe(u8, val);
        }

        if (extractValue(content, "db_path:")) |val| {
            config.db_path = try allocator.dupe(u8, val);
        }

        if (extractValue(content, "output:")) |val| {
            config.output_name = try allocator.dupe(u8, val);
        }

        // ── Boolean flags ────────────────────────────────────────────
        if (std.mem.containsAtLeast(u8, content, 1, "kynx: disabled")) {
            config.no_kynx = true;
        }

        if (std.mem.containsAtLeast(u8, content, 1, "pulse: disabled")) {
            config.pulse_active = false;
        }

        if (std.mem.containsAtLeast(u8, content, 1, "logs: disabled")) {
            config.logs_active = false;
        }

        if (std.mem.containsAtLeast(u8, content, 1, "cache: disabled")) {
            config.cache = false;
        }

        // ── Numeric values ───────────────────────────────────────────
        if (extractLiteral(content, "port:")) |val| {
            config.port = std.fmt.parseInt(u16, val, 10) catch config.port;
        }

        if (extractLiteral(content, "workers:")) |val| {
            config.worker_threads = std.fmt.parseInt(u32, val, 10) catch config.worker_threads;
        }

        if (extractLiteral(content, "keepalive:")) |val| {
            config.keepalive_timeout_s = std.fmt.parseInt(u32, val, 10) catch config.keepalive_timeout_s;
        }

        if (extractLiteral(content, "keepalive_max:")) |val| {
            config.keepalive_max_requests = std.fmt.parseInt(u32, val, 10) catch config.keepalive_max_requests;
        }

        if (extractLiteral(content, "rate:")) |val| {
            const digits = std.mem.trim(u8, val, "ms ");
            config.pulse_rate = std.fmt.parseInt(u32, digits, 10) catch config.pulse_rate;
        }

        if (extractLiteral(content, "arena_pool:")) |val| {
            config.arena_pool_size = std.fmt.parseInt(u32, val, 10) catch config.arena_pool_size;
        }

        if (extractLiteral(content, "arena_size:")) |val| {
            config.arena_default_capacity = std.fmt.parseInt(u32, val, 10) catch config.arena_default_capacity;
        }

        if (extractLiteral(content, "string_pool:")) |val| {
            config.string_pool_capacity = std.fmt.parseInt(u32, val, 10) catch config.string_pool_capacity;
        }

        if (extractLiteral(content, "kynx_pool:")) |val| {
            config.kynx_pool_size = std.fmt.parseInt(u32, val, 10) catch config.kynx_pool_size;
        }

        if (extractLiteral(content, "rate_limit:")) |val| {
            config.kynx_rate_limit = std.fmt.parseInt(u32, val, 10) catch config.kynx_rate_limit;
        }

        if (extractLiteral(content, "kynx_window:")) |val| {
            config.kynx_window_ms = std.fmt.parseInt(u32, val, 10) catch config.kynx_window_ms;
        }

        if (extractLiteral(content, "ban_threshold:")) |val| {
            config.kynx_ban_threshold = std.fmt.parseInt(u32, val, 10) catch config.kynx_ban_threshold;
        }

        return config;
    }

    fn extractValue(content: []const u8, key: []const u8) ?[]const u8 {
        const pos = std.mem.find(u8, content, key) orelse return null;
        const start_quote = std.mem.indexOfScalarPos(u8, content, pos + key.len, '"') orelse return null;
        const end_quote = std.mem.indexOfScalarPos(u8, content, start_quote + 1, '"') orelse return null;
        return content[start_quote + 1 .. end_quote];
    }

    fn extractLiteral(content: []const u8, key: []const u8) ?[]const u8 {
        const pos = std.mem.find(u8, content, key) orelse return null;
        var start = pos + key.len;
        while (start < content.len and (content[start] == ' ' or content[start] == ':')) start += 1;
        var end = start;
        while (end < content.len and content[end] != ',' and content[end] != '\n' and content[end] != '\r' and content[end] != '}') end += 1;
        return std.mem.trim(u8, content[start..end], " \t");
    }
};
