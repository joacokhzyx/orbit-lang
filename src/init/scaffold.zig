//! Orbit Init Project Scaffolding Engine

const std = @import("std");
const templates = @import("templates.zig");
const ui = @import("ui.zig");
const fmt_formatter = @import("../fmt/formatter.zig");
const fmt_rules = @import("../fmt/rules.zig");

pub const InitOptions = struct {
    preset: templates.PresetKind = .microservice,
    enable_ci: bool = false,
};

pub fn scaffoldProject(io: std.Io, allocator: std.mem.Allocator, project_name: []const u8, options: InitOptions, summary: *ui.InitSummary, writer: anytype) !void {
    var cwd = std.Io.Dir.cwd();

    // 1. Create project directory if not "."
    const is_current_dir = std.mem.eql(u8, project_name, ".");
    if (!is_current_dir) {
        cwd.createDirPath(io, project_name) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const target_dir_path = if (is_current_dir) "." else project_name;

    // 2. Scaffold main.orb (or lib.orb for library preset)
    const main_filename = if (options.preset == .library) "lib.orb" else "main.orb";
    const raw_code = try templates.getTemplateCode(options.preset, project_name, allocator);
    defer allocator.free(raw_code);

    // Format template code with Orbit Formatter
    const formatted_code = try fmt_formatter.formatSource(allocator, raw_code, fmt_rules.FormatterOptions{});
    defer allocator.free(formatted_code);

    const main_file_path = try std.fs.path.join(allocator, &.{ target_dir_path, main_filename });
    defer allocator.free(main_file_path);

    try writeFileContent(io, cwd, main_file_path, formatted_code);
    summary.files_created += 1;
    try ui.renderStep(writer, "Created", main_file_path);

    // 3. Scaffold orbit.config.json
    const config_json = try templates.getOrbitConfigJson(project_name, options.preset, allocator);
    defer allocator.free(config_json);

    const config_file_path = try std.fs.path.join(allocator, &.{ target_dir_path, "orbit.config.json" });
    defer allocator.free(config_file_path);

    try writeFileContent(io, cwd, config_file_path, config_json);
    summary.files_created += 1;
    try ui.renderStep(writer, "Created", config_file_path);

    // 4. Scaffold .gitignore
    const gitignore_content = try templates.getGitIgnoreContent(allocator);
    defer allocator.free(gitignore_content);

    const gitignore_file_path = try std.fs.path.join(allocator, &.{ target_dir_path, ".gitignore" });
    defer allocator.free(gitignore_file_path);

    try writeFileContent(io, cwd, gitignore_file_path, gitignore_content);
    summary.files_created += 1;
    try ui.renderStep(writer, "Created", gitignore_file_path);

    // 5. Scaffold .github/workflows/ci.yml if --ci flag is enabled
    if (options.enable_ci) {
        const github_dir = try std.fs.path.join(allocator, &.{ target_dir_path, ".github", "workflows" });
        defer allocator.free(github_dir);

        cwd.createDirPath(io, github_dir) catch {};

        const ci_content = try templates.getCiWorkflowContent(project_name, allocator);
        defer allocator.free(ci_content);

        const ci_file_path = try std.fs.path.join(allocator, &.{ github_dir, "ci.yml" });
        defer allocator.free(ci_file_path);

        try writeFileContent(io, cwd, ci_file_path, ci_content);
        summary.files_created += 1;
        try ui.renderStep(writer, "Generated", ci_file_path);
    }
}

fn writeFileContent(io: std.Io, cwd: std.Io.Dir, path: []const u8, content: []const u8) !void {
    var out_file = try cwd.createFile(io, path, .{ .truncate = true });
    defer out_file.close(io);
    var write_buf: [4096]u8 = undefined;
    var writer_state = std.Io.File.Writer.init(out_file, io, &write_buf);
    try writer_state.interface.writeAll(content);
    try writer_state.flush();
}
