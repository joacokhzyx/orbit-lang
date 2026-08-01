//! Orbit Init Template Generator
//! Production-grade starters for Microservice, Database App, Secured API, and Library presets.

const std = @import("std");

pub const PresetKind = enum {
    microservice,
    database_app,
    secured_api,
    library,

    pub fn fromString(str: []const u8) ?PresetKind {
        if (std.mem.eql(u8, str, "microservice") or std.mem.eql(u8, str, "api")) return .microservice;
        if (std.mem.eql(u8, str, "database") or std.mem.eql(u8, str, "database_app") or std.mem.eql(u8, str, "db")) return .database_app;
        if (std.mem.eql(u8, str, "secured") or std.mem.eql(u8, str, "secured_api") or std.mem.eql(u8, str, "kynx")) return .secured_api;
        if (std.mem.eql(u8, str, "library") or std.mem.eql(u8, str, "lib")) return .library;
        return null;
    }
};

pub fn getTemplateCode(preset: PresetKind, project_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    switch (preset) {
        .microservice => return try std.fmt.allocPrint(allocator,
            \\// Orbit Microservice API Template — {s}
            \\// Provides health probes, readiness probes, and metrics endpoints.
            \\
            \\route GET "/health" {{
            \\    val uptime = system.uptime()
            \\    return ok 200 "{{\"status\":\"UP\",\"project\":\"{s}\",\"uptime_seconds\":" + uptime + "}}"
            \\}}
            \\
            \\route GET "/ready" {{
            \\    return ok 200 "{{\"ready\":true,\"project\":\"{s}\",\"accepting_traffic\":true}}"
            \\}}
            \\
            \\route GET "/metrics" {{
            \\    val total = system.http_requests_total()
            \\    val success = system.http_requests_success()
            \\    val error = system.http_requests_error()
            \\    return ok 200 "{{\"metrics\":{{\"total\":" + total + ",\"success\":" + success + ",\"error\":" + error + "}}}}"
            \\}}
            \\
        , .{ project_name, project_name, project_name }),
        .database_app => return try std.fmt.allocPrint(allocator,
            \\// Orbit Database ORM App Template — {s}
            \\// Uses native Model ORM methods and SQLite persistence.
            \\
            \\model Product {{
            \\    id: string
            \\    name: string
            \\    price: float
            \\    category: string
            \\    in_stock: bool
            \\}}
            \\
            \\route GET "/v1/products" {{
            \\    val category = req.query("category")
            \\    if (category != "") {{
            \\        val filtered = Product.where("category = ?", category)
            \\        return ok 200 filtered
            \\    }}
            \\    val all_products = Product.all()
            \\    return ok 200 all_products
            \\}}
            \\
            \\route POST "/v1/products" {{
            \\    val body = req.body()
            \\    val created = Product.create(body)
            \\    if (created) {{
            \\        return ok 201 "{{\"status\":\"created\",\"project\":\"{s}\",\"message\":\"Product saved to SQLite database\"}}"
            \\    }}
            \\    err 400 "Failed to insert product"
            \\}}
            \\
        , .{ project_name, project_name }),
        .secured_api => return try std.fmt.allocPrint(allocator,
            \\// Orbit Kynx Secured Enterprise API Template — {s}
            \\// Pre-configured with zero-trust audit headers, rate limiting, and status guards.
            \\
            \\route GET "/v1/secure/resource" {{
            \\    val auth_header = req.header("Authorization")
            \\    if (auth_header == "") {{
            \\        err 401 "Unauthorized: missing access token"
            \\    }}
            \\    return ok 200 "{{\"status\":\"access_granted\",\"project\":\"{s}\",\"shield\":\"Kynx Active\"}}"
            \\}}
            \\
            \\route GET "/v1/secure/audit" {{
            \\    val uptime = system.uptime()
            \\    return ok 200 "{{\"audit\":{{\"engine\":\"Kynx Zero-Trust\",\"project\":\"{s}\",\"uptime\":" + uptime + "}}}}"
            \\}}
            \\
        , .{ project_name, project_name, project_name }),
        .library => return try std.fmt.allocPrint(allocator,
            \\// Orbit Modular Library Template — {s}
            \\// Exports domain helpers and mathematical utility functions.
            \\
            \\fn add(a: int, b: int) -> int {{
            \\    return a + b
            \\}}
            \\
            \\fn multiply(a: int, b: int) -> int {{
            \\    return a * b
            \\}}
            \\
            \\fn is_even(n: int) -> bool {{
            \\    return n % 2 == 0
            \\}}
            \\
        , .{project_name}),
    }
}

pub fn getOrbitConfigJson(project_name: []const u8, preset: PresetKind, allocator: std.mem.Allocator) ![]u8 {
    const preset_str = @tagName(preset);
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "backend": "c",
        \\  "preset": "{s}",
        \\  "kynx": true,
        \\  "optimization": "release_fast"
        \\}}
        \\
    , .{ project_name, preset_str });
}

pub fn getGitIgnoreContent(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8,
        \\# Orbit Build Artifacts & Cache
        \\.orbit-cache/
        \\orbit-out/
        \\*.exe
        \\*.obj
        \\*.o
        \\*.pdb
        \\.zig-cache/
        \\zig-out/
        \\
    );
}

pub fn getCiWorkflowContent(project_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\name: Orbit CI Workflow - {s}
        \\
        \\on:
        \\  push:
        \\    branches: [ main, master ]
        \\  pull_request:
        \\    branches: [ main, master ]
        \\
        \\jobs:
        \\  build-and-test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - name: Setup Zig & Orbit
        \\        uses: mlugg/setup-zig@v1
        \\        with:
        \\          version: master
        \\      - name: Verify Formatting
        \\        run: orbit fmt --check .
        \\      - name: Run Diagnostics
        \\        run: orbit doctor .
        \\      - name: Build C Target
        \\        run: orbit build main.orb --backend=c
        \\
    , .{project_name});
}
