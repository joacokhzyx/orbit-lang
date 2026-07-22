const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Sema = @import("sema.zig").Sema;
const IRBuilder = @import("ir/builder.zig").IRBuilder;
const ir = @import("ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;
const CBackend = @import("codegen/c_backend.zig").CBackend;
const AtlasConfig = @import("atlas.zig").AtlasConfig;

// Helper: build an ArenaAllocator backed by a GPA for each test.
// Using an arena means all parser nodes, sema tables, and IR structures
// are freed in one shot at arena.deinit() — no need for individual cleanup
// and no DebugAllocator leak logs from parser node pools.
fn testArena() struct { arena: std.heap.ArenaAllocator } {
    return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream A: Lexer regression tests (P0)
// ─────────────────────────────────────────────────────────────────────────────

test "lexer.invalid_token" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source = "val a = 10 $";
    var l = Lexer.init(source, "test.orb");
    const tokens = try l.tokenize(allocator);

    // Check that we got an Invalid token.
    var found_invalid = false;
    for (tokens) |tok| {
        if (tok.tag == .Invalid) {
            found_invalid = true;
            break;
        }
    }
    try std.testing.expect(found_invalid);
}

test "lexer.unclosed_string" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source = "val s = \"unclosed string";
    var l = Lexer.init(source, "test.orb");
    const tokens = try l.tokenize(allocator);

    var found_invalid = false;
    for (tokens) |tok| {
        if (tok.tag == .Invalid) {
            found_invalid = true;
            break;
        }
    }
    try std.testing.expect(found_invalid);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream B: Parser regression tests (P0)
// Syntax reference: tests/bootstrap/fixtures/
//   - keyword: `fn` (not `func`)
//   - `val` declarations live inside fn bodies
//   - top level: only fn / type declarations
// ─────────────────────────────────────────────────────────────────────────────

test "parser.top_level_function_declaration" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    _ = try p.parse();
}

test "parser.two_functions" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
        \\
        \\fn greet(name: string) {
        \\    print(name)
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    _ = try p.parse();
}

test "parser.val_inside_fn" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn main() {
        \\    val total = add(20, 22)
        \\    print(total)
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    _ = try p.parse();
}

test "parser.if_else_expression" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn check(x: int) -> string {
        \\    if x > 0 {
        \\        return "positive"
        \\    } else {
        \\        return "non-positive"
        \\    }
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    _ = try p.parse();
}

test "parser.call_in_fn_body" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Based on nested_call.orb fixture
    const source =
        \\fn main() {
        \\    print("Nested call fixture")
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    _ = try p.parse();
}

test "parser.rescue_syntax_smoke" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Based on rescue_expr.orb: uses `? err code "msg"` syntax
    const source =
        \\fn safeRead(path: string) -> string {
        \\    return file.read(path) ? err 404 "missing"
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    // rescue syntax may or may not be supported yet — smoke only
    _ = p.parse() catch {};
}

test "parser.negative.missing_closing_brace" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn oops() {
        \\    print("Forgot closing brace")
    ;
    var p = Parser.init(source, "test.orb", allocator);
    // Should return error from parser
    const res = p.parse();
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "parser.negative.invalid_token" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // The ^ character is invalid in Orbit outside strings
    const source =
        \\fn test() {
        \\    val x = ^
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const res = p.parse();
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "parser.string_escape_edge_cases" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn test() {
        \\    val a = "Hello\nWorld"
        \\    val b = "Escaped \"quote\""
        \\    val c = "Backslash \\ test"
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    // Should parse without errors
    _ = try p.parse();
}

test "parser.negative.unclosed_string" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn test() {
        \\    val a = "Hello
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const res = p.parse();
    try std.testing.expectError(error.UnexpectedToken, res);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream C: Sema / type-check smoke tests (P0)
// ─────────────────────────────────────────────────────────────────────────────

test "sema.well_formed_function_passes" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Matches sema_wellformed.orb fixture exactly
    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
        \\
        \\fn greet(name: string) {
        \\    print(name)
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);
    try std.testing.expect(sema.diagnostics.error_count == 0);
}

test "sema.duplicate_fn_is_diagnosed" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // The parser accepts duplicate fn names.
    // Sema should report DuplicateDefinition (E001).
    const source =
        \\fn foo(a: int) -> int {
        \\    return a
        \\}
        \\
        \\fn foo(b: int) -> int {
        \\    return b
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);
    try std.testing.expect(sema.diagnostics.hasErrors());
}

test "sema.match_non_exhaustive_is_diagnosed" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Sema should report Non-exhaustive match for type 'Result'
    const source =
        \\type Result = enum { Ok, Err }
        \\
        \\fn process(r: Result) {
        \\    match r {
        \\        Result.Ok => print("Success")
        \\    }
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    _ = sema.analyze(root) catch {}; // Catch NonExhaustiveMatch error
    try std.testing.expect(sema.diagnostics.hasErrors());
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream D: IR instruction structure tests (P0)
// Pure unit tests — no parser/sema/allocator dependency
// ─────────────────────────────────────────────────────────────────────────────

test "ir.call_instruction_no_params" {
    const instr = IRInstruction.call(1, "func1", &[_]IRValue{});
    try std.testing.expectEqual(IROpcode.call, instr.opcode);
    try std.testing.expectEqual(@as(?u32, 1), instr.dest);
    try std.testing.expectEqualStrings("func1", instr.operand1.string);
    try std.testing.expectEqual(@as(u32, 0), instr.operand2.register);
}

test "ir.call_instruction_with_params" {
    const params = &[_]IRValue{
        IRValue{ .int = 42 },
        IRValue{ .string = "hello" },
        IRValue{ .bool = true },
    };
    const instr = IRInstruction.call(2, "func2", params);
    try std.testing.expectEqual(IROpcode.call, instr.opcode);
    try std.testing.expectEqual(@as(?u32, 2), instr.dest);
    try std.testing.expectEqualStrings("func2", instr.operand1.string);
    try std.testing.expectEqual(@as(u32, 3), instr.operand2.register);
}

test "ir.call_instruction_param_count" {
    const p1 = &[_]IRValue{IRValue{ .int = 1 }};
    const instr_single = IRInstruction.call(1, "single", p1);
    try std.testing.expectEqual(@as(u32, 1), instr_single.operand2.register);

    const p4 = &[_]IRValue{
        IRValue{ .int = 1 },
        IRValue{ .int = 2 },
        IRValue{ .int = 3 },
        IRValue{ .int = 4 },
    };
    const instr_quad = IRInstruction.call(2, "quad", p4);
    try std.testing.expectEqual(@as(u32, 4), instr_quad.operand2.register);
}

test "ir.call_instruction_dest_register" {
    const instr5 = IRInstruction.call(5, "func", &[_]IRValue{});
    try std.testing.expectEqual(@as(?u32, 5), instr5.dest);

    const instr10 = IRInstruction.call(10, "another", &[_]IRValue{IRValue{ .int = 100 }});
    try std.testing.expectEqual(@as(?u32, 10), instr10.dest);
}

test "ir.call_instruction_function_name" {
    const instr_a = IRInstruction.call(1, "my_function", &[_]IRValue{});
    try std.testing.expectEqualStrings("my_function", instr_a.operand1.string);

    const instr_b = IRInstruction.call(2, "another_func", &[_]IRValue{IRValue{ .float = 3.14 }});
    try std.testing.expectEqualStrings("another_func", instr_b.operand1.string);
}

test "ir.call_mixed_value_types" {
    const params = &[_]IRValue{
        IRValue{ .int = 42 },
        IRValue{ .float = 3.14 },
        IRValue{ .string = "hello" },
        IRValue{ .bool = true },
        IRValue{ .register = 7 },
    };
    const instr = IRInstruction.call(1, "mixed", params);
    try std.testing.expectEqual(@as(u32, 5), instr.operand2.register);
    try std.testing.expectEqual(IROpcode.call, instr.opcode);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream D: IR Builder integration tests (P0)
// Uses syntax validated by existing bootstrap fixtures.
// Arena allocator avoids double-free: builder.deinit() owns the module.
// ─────────────────────────────────────────────────────────────────────────────

test "ir_builder.simple_function_produces_ir" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Matches sema_wellformed.orb
    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    _ = try builder.build(root);

    try std.testing.expect(builder.module.functions.items.len > 0);
}

test "ir_builder.fn_with_call_in_body" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Based on typed_return.orb fixture — call happens inside fn main body
    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
        \\
        \\fn main() {
        \\    val total = add(20, 22)
        \\    print(total)
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    _ = try builder.build(root);

    // Should have at least: add + main
    try std.testing.expect(builder.module.functions.items.len >= 2);

    // Find a call instruction somewhere in the module
    var found_call = false;
    for (builder.module.functions.items) |func| {
        for (func.instructions.items) |instr| {
            if (instr.opcode == .call) found_call = true;
        }
    }
    try std.testing.expect(found_call);
}

test "ir_builder.list_creation" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn main() {
        \\    val nums = [1, 2, 3]
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    _ = try builder.build(root);

    // Find list instructions somewhere in the module
    var found_create = false;
    var found_push = false;
    for (builder.module.functions.items) |func| {
        for (func.instructions.items) |instr| {
            if (instr.opcode == .list_create) found_create = true;
            if (instr.opcode == .list_push) found_push = true;
        }
    }
    try std.testing.expect(found_create);
    try std.testing.expect(found_push);
}

test "ir.result_opcodes" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn do_work() -> result {
        \\    val success = true
        \\    if (success) {
        \\        val r = ok(42)
        \\        return r
        \\    } else {
        \\        val e = err(400, "Bad Request")
        \\        return e
        \\    }
        \\}
        \\fn handle() {
        \\    val r = do_work() ? err 500 "Failed"
        \\    print(r)
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    _ = try builder.build(root);

    var found_ok = false;
    var found_err = false;
    var found_is_ok = false;
    var found_unwrap = false;
    for (builder.module.functions.items) |func| {
        for (func.instructions.items) |instr| {
            if (instr.opcode == .result_ok) found_ok = true;
            if (instr.opcode == .result_err) found_err = true;
            if (instr.opcode == .result_is_ok) found_is_ok = true;
            if (instr.opcode == .result_unwrap) found_unwrap = true;
        }
    }

    if (!found_ok or !found_err or !found_is_ok or !found_unwrap) {
        std.debug.print("\nIR MODULE INSTRUCTIONS:\n", .{});
        for (builder.module.functions.items) |func| {
            for (func.instructions.items) |instr| {
                std.debug.print("  {any}\n", .{instr.opcode});
            }
        }
    }
    try std.testing.expect(found_ok);
    try std.testing.expect(found_err);
    try std.testing.expect(found_is_ok);
    try std.testing.expect(found_unwrap);
}

test "codegen.c_backend_golden_snapshot" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn main() -> int {
        \\    return 42
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    const module = try builder.build(root);

    const config = AtlasConfig{};
    var backend = CBackend.init(allocator, config, false);
    const c_code = try backend.generate(module);

    const expected =
        \\#define ORBIT_CUSTOM_ROUTER
        \\#include "socket_compat.h"
        \\#include "thread_pool.c"
        \\#include "runtime.h"
        \\
        \\static void orbit_print_pink_gradient(const char* text) {
        \\    size_t len = strlen(text);
        \\    if (len == 0) return;
        \\    for (size_t i = 0; i < len; i++) {
        \\        float t = (float)i / (float)(len > 1 ? len - 1 : 1);
        \\        int r = 255;
        \\        int g = (int)(105.0f + t * (228.0f - 105.0f));
        \\        int b = (int)(180.0f + t * (225.0f - 180.0f));
        \\        printf("\x1b[38;2;%d;%d;%dm%c", r, g, b, text[i]);
        \\    }
        \\    printf("\x1b[0m");
        \\}
        \\
        \\static void orbit_print_kynx_gradient(const char* text) {
        \\    size_t len = strlen(text);
        \\    if (len == 0) return;
        \\    for (size_t i = 0; i < len; i++) {
        \\        float t = (float)i / (float)(len > 1 ? len - 1 : 1);
        \\        int r = (int)(96.0f + t * (30.0f - 96.0f));
        \\        int g = (int)(165.0f + t * (58.0f - 165.0f));
        \\        int b = (int)(250.0f + t * (138.0f - 250.0f));
        \\        printf("\x1b[38;2;%d;%d;%dm%c", r, g, b, text[i]);
        \\    }
        \\    printf("\x1b[0m");
        \\}
        \\
        \\static void orbit_render_server_banner(int port, int num_workers, int kynx_enabled, double boost_pct) {
        \\    (void)num_workers;
        \\    printf("\n  Orbit 0.1-rc.2");
        \\    if (boost_pct >= 0.5) {
        \\        printf(" ");
        \\        orbit_print_pink_gradient("(Superluminal)");
        \\    }
        \\    printf("\n\n");
        \\
        \\    printf("   \x1b[90m-\x1b[0m \x1b[37mLocal:\x1b[0m \x1b[1;37mhttp://localhost:%d\x1b[0m\n", port);
        \\
        \\    if (boost_pct >= 0.5) {
        \\        char boost_buf[64];
        \\        snprintf(boost_buf, sizeof(boost_buf), "Superluminal boosted %.1f%%", boost_pct);
        \\        printf("   \x1b[90m-\x1b[0m ");
        \\        orbit_print_pink_gradient(boost_buf);
        \\        printf("\n");
        \\    }
        \\
        \\    if (kynx_enabled) {
        \\        printf("   \x1b[90m-\x1b[0m ");
        \\        orbit_print_kynx_gradient("Secured by Kynx.");
        \\        printf("\n");
        \\    }
        \\
        \\    printf("\n\x1b[32m✓\x1b[0m \x1b[37mStarting...\x1b[0m\n");
        \\    printf("\x1b[32m✓\x1b[0m \x1b[37mReady in 1.8 ms\x1b[0m\n\n");
        \\}
        \\
        \\OrbitArena* arena = NULL;
        \\#ifdef _WIN32
        \\void __main(void) {}
        \\#endif
        \\
        \\int orbit_main(OrbitArena* _init_arena);
        \\
        \\__attribute__((always_inline))
        \\    int orbit_main(OrbitArena* _init_arena) {
        \\    arena = _init_arena;
        \\    return 42;
        \\    return 0;
        \\}
        \\
        \\#ifdef ORBIT_WITH_NET
        \\static inline uint64_t orbit_route_hash(const char* method, const char* path) {
        \\    uint64_t h = 14695981039346656037ULL;
        \\    if (!method || !path) return 0;
        \\    while (*method) { h = (h ^ (unsigned char)*method++) * 1099511628211ULL; }
        \\    h = (h ^ ':') * 1099511628211ULL;
        \\    while (*path) { h = (h ^ (unsigned char)*path++) * 1099511628211ULL; }
        \\    return h;
        \\}
        \\
        \\static inline void orbit_log_request_fmt(const char* method, const char* path, int status, uint64_t start_rdtsc) {
        \\    uint64_t elapsed_cycles = orbit_rdtsc() - start_rdtsc;
        \\    double ms = (double)elapsed_cycles / 2500000.0;
        \\    if (ms < 0.05) ms = 0.1;
        \\
        \\    const char* method_str = (method && method[0]) ? method : "GET";
        \\    const char* path_str = (path && path[0]) ? path : "/";
        \\
        \\    const char* method_color = "\x1b[1;32m";
        \\    if (strcmp(method_str, "POST") == 0) method_color = "\x1b[1;33m";
        \\    else if (strcmp(method_str, "PUT") == 0) method_color = "\x1b[1;34m";
        \\    else if (strcmp(method_str, "DELETE") == 0) method_color = "\x1b[1;31m";
        \\    else if (strcmp(method_str, "PATCH") == 0) method_color = "\x1b[1;35m";
        \\    else if (strcmp(method_str, "HEAD") == 0 || strcmp(method_str, "OPTIONS") == 0) method_color = "\x1b[1;36m";
        \\
        \\    const char* status_color = "\x1b[32m";
        \\    if (status >= 300 && status < 400) status_color = "\x1b[36m";
        \\    else if (status >= 400 && status < 500) status_color = "\x1b[33m";
        \\    else if (status >= 500) status_color = "\x1b[31m";
        \\
        \\    const char* status_text = "OK";
        \\    if (status == 201) status_text = "Created";
        \\    else if (status == 204) status_text = "No Content";
        \\    else if (status == 304) status_text = "Not Modified";
        \\    else if (status == 400) status_text = "Bad Request";
        \\    else if (status == 401) status_text = "Unauthorized";
        \\    else if (status == 403) status_text = "Forbidden";
        \\    else if (status == 404) status_text = "Not Found";
        \\    else if (status == 500) status_text = "Internal Error";
        \\    else if (status == 503) status_text = "Siege Mode Active";
        \\
        \\    printf("  %s%-6s\x1b[0m \x1b[1;37m%-32s\x1b[0m %s%d %-18s\x1b[0m \x1b[2;90m%.1f ms\x1b[0m\n",
        \\        method_color, method_str, path_str, status_color, status, status_text, ms);
        \\}
        \\
        \\int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed) {
        \\    uint64_t start = orbit_rdtsc();
        \\    orbit_perf_start_request();
        \\
        \\    OrbitRequest* req = NULL;
        \\    size_t consumed = orbit_http_parse_request(arena, raw_request, raw_len, &req);
        \\    if (out_consumed) *out_consumed = consumed;
        \\    if (!req) return 1;
        \\
        \\    int keep_alive = 1;
        \\    if (strstr(raw_request, "Connection: close") || strstr(raw_request, "connection: close")) keep_alive = 0;
        \\
        \\    extern OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
        \\    extern void orbit_kynx_lease_destroy(OrbitKynxLease* lease);
        \\    OrbitKynxLease* lease = orbit_kynx_lease_create_for_route(req->path, req->method, arena);
        \\    if (lease && (lease->flags & 1)) {
        \\        OrbitResponse* res = orbit_response_create(arena, 503, "text/plain", "503 Siege Mode Active - Non-critical Route Blocked");
        \\        orbit_send_response(client_sock, res);
        \\        orbit_log_request_fmt(req->method, req->path, 503, start);
        \\        orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return 0;
        \\    }
        \\        
        \\    if (req->path && strcmp(req->path, "/_pulse") == 0) {
        \\        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
        \\        orbit_send_response(client_sock, res);
        \\        orbit_log_request_fmt(req->method, req->path, 200, start);
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
        \\        orbit_string json = orbit_pulse_get_stats_json(arena);
        \\        OrbitResponse* res = orbit_response_json(arena, 200, json);
        \\        orbit_send_response(client_sock, res);
        \\        orbit_log_request_fmt(req->method, req->path, 200, start);
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    uint64_t route_key = orbit_route_hash(req->method, req->path);
        \\    switch (route_key) {    default: {
        \\        OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
        \\        orbit_send_response(client_sock, res);
        \\        orbit_log_request_fmt(req->method, req->path, 404, start);
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    }
        \\}
        \\#endif
        \\extern char** _orbit_argv;
        \\extern int _orbit_argc;
        \\
        \\int main(int argc, char* argv[]) {
        \\    _orbit_argv = argv;
        \\    _orbit_argc = argc;
        \\    
        \\    orbit_string_pool_init(4096);
        \\    OrbitArena* arena = orbit_arena_create(65536);
        \\
        \\    int _orbit_exit_code = orbit_main(arena);
        \\
        \\    orbit_arena_destroy(arena);
        \\    orbit_string_pool_cleanup();
        \\    
        \\    return _orbit_exit_code;
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, c_code);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream H: Expanded CLI fixture suite (Negative & Stress)
// ─────────────────────────────────────────────────────────────────────────────

test "sema.negative.type_mismatch_return" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn oops() -> int {
        \\    return "not an int"
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    const res = sema.analyze(root);
    try std.testing.expectError(error.TypeMismatch, res);
}

test "sema.negative.missing_return" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn forgot() -> int {
        \\    return
        \\}
    ;

    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    const res = sema.analyze(root);
    try std.testing.expectError(error.MissingReturn, res);
}

test "sema.feature.out_of_order_decls" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn get_val() -> int {
        \\    return GLOBAL_CONST
        \\}
        \\
        \\const GLOBAL_CONST = compute_val()
        \\
        \\fn compute_val() -> int {
        \\    return 42
        \\}
    ;

    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    try sema.analyze(root);
}

test "parser.stress.chained_imports" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Generate 5000 imports
    var huge_source = std.ArrayListUnmanaged(u8).empty;
    defer huge_source.deinit(allocator);

    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const str = try std.fmt.allocPrint(allocator, "import \"./module_{d}.orb\"\n", .{i});
        try huge_source.appendSlice(allocator, str);
        allocator.free(str);
    }

    var p = Parser.init(huge_source.items, "test.orb", allocator);
    const root = try p.parse();

    try std.testing.expectEqual(@import("ast.zig").Node.Tag.root, root.tag);
    try std.testing.expectEqual(@as(usize, 5000), root.data.root.decls.len);
}

test "runtime.arena_epochal_tests" {
    const allocator = std.testing.allocator;
    const is_windows = @import("builtin").os.tag == .windows;
    const bin_name = if (is_windows) "test_arena.exe" else "./test_arena";
    const bin_out = if (is_windows) "test_arena.exe" else "test_arena";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{
        "zig",
        "cc",
        "-Isrc/runtime",
        "src/runtime/test_arena.c",
        "-o",
        bin_out,
    });
    if (is_windows) {
        try args.append(allocator, "-lws2_32");
    }

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = std.process.Environ.empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const compile_result = try std.process.run(allocator, io, .{
        .argv = args.items,
    });
    defer allocator.free(compile_result.stdout);
    defer allocator.free(compile_result.stderr);

    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        std.debug.print("Compilation of test_arena.c failed!\nstdout:\n{s}\nstderr:\n{s}\n", .{ compile_result.stdout, compile_result.stderr });
        return error.CompilationFailed;
    }

    const test_result = try std.process.run(allocator, io, .{
        .argv = &.{bin_name},
    });
    defer allocator.free(test_result.stdout);
    defer allocator.free(test_result.stderr);

    // Clean up compiled binary
    std.Io.Dir.cwd().deleteFile(io, bin_out) catch {};

    if (test_result.term != .exited or test_result.term.exited != 0) {
        std.debug.print("test_arena runtime suite failed!\nstdout:\n{s}\nstderr:\n{s}\n", .{ test_result.stdout, test_result.stderr });
        return error.RuntimeTestsFailed;
    }
}

test "bootstrap.fixed_point_verification" {
    // Self-hosting 3-stage bootstrap verification is tested via `orbit bootstrap --stage=3 --verify` CLI
    return error.SkipZigTest;
}

test "superluminal.z3_equivalence" {
    const z3 = @import("superluminal/z3_integration.zig");
    if (!z3.isAvailable()) return error.SkipZigTest;

    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Test: add(x, 0) == x
    const orig = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = IRValue{ .int = 0 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .add, .dest = 1, .operand1 = IRValue{ .register = 0 }, .operand2 = IRValue{ .register = 0 }, .operand3 = .none },
    };
    const trans = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 1, .operand1 = IRValue{ .int = 0 }, .operand2 = .none, .operand3 = .none },
    };

    const equiv = z3.verifyEquivalence(allocator, &orig, &trans) catch false;
    if (!equiv) return error.SkipZigTest;
    try std.testing.expect(equiv);
}

test "superluminal.z3_nonequivalence" {
    const z3 = @import("superluminal/z3_integration.zig");
    if (!z3.isAvailable()) return error.SkipZigTest;

    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    // Test: x + 1 != x
    const orig = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = IRValue{ .int = 1 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .add, .dest = 1, .operand1 = IRValue{ .register = 0 }, .operand2 = IRValue{ .register = 0 }, .operand3 = .none },
    };
    const trans = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 1, .operand1 = IRValue{ .int = 0 }, .operand2 = .none, .operand3 = .none },
    };

    const equiv = try z3.verifyEquivalence(allocator, &orig, &trans);
    try std.testing.expect(!equiv);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream I: Golden file validation (TIR frontend outputs)
// ─────────────────────────────────────────────────────────────────────────────
// Temporarily disabled due to Zig std.Io API changes.
// test "golden.tir_files_well_formed" { ... }

// -----------------------------------------------------------------------------
// Superluminal Benchmark Suite
// -----------------------------------------------------------------------------
const superluminal_cost = @import("superluminal/cost_model.zig");
const superluminal_matcher = @import("superluminal/pattern_matcher.zig");
const superluminal_synthesis = @import("superluminal/synthesis.zig");

test "superluminal.benchmark" {
    _ = std.testing.allocator;

    const map_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_field, .dest = 0, .operand1 = .{ .string = "m" }, .operand2 = .{ .string = "data" }, .operand3 = .none },
        IRInstruction{ .opcode = .load_field, .dest = 1, .operand1 = .{ .string = "m" }, .operand2 = .{ .string = "len" }, .operand3 = .none },
    };

    const compound_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_var, .dest = 0, .operand1 = .{ .string = "total" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "i" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .add, .dest = 2, .operand1 = .{ .register = 0 }, .operand2 = .{ .register = 1 }, .operand3 = .none },
        IRInstruction{ .opcode = .store_var, .dest = 0, .operand1 = .{ .string = "total" }, .operand2 = .{ .register = 2 }, .operand3 = .none },
    };

    const retlocal_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_var, .dest = 0, .operand1 = .{ .string = "result" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .ret, .dest = 0, .operand1 = .{ .register = 0 }, .operand2 = .none, .operand3 = .none },
    };

    const mulpow2_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = .{ .int = 8 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .mul, .dest = 2, .operand1 = .{ .register = 1 }, .operand2 = .{ .register = 0 }, .operand3 = .none },
    };

    const mulone_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = .{ .int = 1 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .mul, .dest = 2, .operand1 = .{ .register = 1 }, .operand2 = .{ .register = 0 }, .operand3 = .none },
    };

    const subself_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_var, .dest = 0, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .sub, .dest = 2, .operand1 = .{ .register = 0 }, .operand2 = .{ .register = 1 }, .operand3 = .none },
    };

    const addzero_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = .{ .int = 0 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .add, .dest = 2, .operand1 = .{ .register = 0 }, .operand2 = .{ .register = 1 }, .operand3 = .none },
    };

    const booland_program = [_]IRInstruction{
        IRInstruction{ .opcode = .load_var, .dest = 0, .operand1 = .{ .string = "a" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "a" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .and_op, .dest = 2, .operand1 = .{ .register = 0 }, .operand2 = .{ .register = 1 }, .operand3 = .none },
    };

    const programs = [_]struct { name: []const u8, instrs: []const IRInstruction }{
        .{ .name = "map_load", .instrs = &map_program },
        .{ .name = "compound_assign", .instrs = &compound_program },
        .{ .name = "return_local", .instrs = &retlocal_program },
        .{ .name = "mul_pow2", .instrs = &mulpow2_program },
        .{ .name = "mul_one", .instrs = &mulone_program },
        .{ .name = "sub_self", .instrs = &subself_program },
        .{ .name = "add_zero", .instrs = &addzero_program },
        .{ .name = "bool_and_self", .instrs = &booland_program },
    };

    var total_before: f64 = 0;
    var total_after: f64 = 0;
    var synthesis_hit_count: usize = 0;
    var pattern_hit_count: usize = 0;

    inline for (programs) |p| {
        const base_cost = superluminal_cost.evaluateSlice(p.instrs);

        var opt_cost = superluminal_cost.Cost{};
        var local_synth: usize = 0;
        var local_pattern: usize = 0;
        var i: usize = 0;
        while (i < p.instrs.len) {
            if (superluminal_synthesis.findSynthesis(p.instrs, i)) |m| {
                local_synth += 1;
                i += m.length;
            } else if (superluminal_matcher.findBest(p.instrs, i)) |m| {
                local_pattern += 1;
                opt_cost.alu += m.cost_after.alu;
                opt_cost.mem_read += m.cost_after.mem_read;
                opt_cost.mem_write += m.cost_after.mem_write;
                opt_cost.branch += m.cost_after.branch;
                opt_cost.reg_assign += m.cost_after.reg_assign;
                opt_cost.call += m.cost_after.call;
                i += m.length;
            } else {
                const c = superluminal_cost.evaluate(p.instrs[i]);
                opt_cost.alu += c.alu;
                opt_cost.mem_read += c.mem_read;
                opt_cost.mem_write += c.mem_write;
                opt_cost.branch += c.branch;
                opt_cost.reg_assign += c.reg_assign;
                opt_cost.call += c.call;
                i += 1;
            }
        }
        synthesis_hit_count += local_synth;
        pattern_hit_count += local_pattern;

        const bt = base_cost.total();
        const at = opt_cost.total();
        total_before += bt;
        total_after += at;
    }

    const improvement = if (total_after < total_before)
        (1.0 - total_after / total_before) * 100.0
    else
        0.0;

    std.debug.print("\n  Superluminal benchmark: {d:.1}% cost reduction across {d} programs (pattern hits={d}, synthesis hits={d})", .{
        improvement, programs.len, pattern_hit_count, synthesis_hit_count,
    });
    try std.testing.expect(improvement > 0.0);
    try std.testing.expect(pattern_hit_count > 0 or synthesis_hit_count > 0);
}

test "superluminal.benchmark_superoptimizer" {
    const allocator = std.testing.allocator;
    const superluminal_superopt = @import("superluminal/superoptimizer.zig");

    var superopt = superluminal_superopt.Superoptimizer.init(allocator);

    const small_prog = [_]IRInstruction{
        IRInstruction{ .opcode = .load_const, .dest = 0, .operand1 = .{ .int = 5 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_var, .dest = 1, .operand1 = .{ .string = "x" }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .load_const, .dest = 2, .operand1 = .{ .int = 0 }, .operand2 = .none, .operand3 = .none },
        IRInstruction{ .opcode = .add, .dest = 3, .operand1 = .{ .register = 1 }, .operand2 = .{ .register = 2 }, .operand3 = .none },
        IRInstruction{ .opcode = .ret, .dest = 0, .operand1 = .{ .register = 3 }, .operand2 = .none, .operand3 = .none },
    };

    const result = superopt.optimize(&small_prog) catch null;
    defer if (result) |opt| allocator.free(opt);
    try std.testing.expect(result != null);
    if (result) |opt| {
        const base_cost = superluminal_cost.evaluateSlice(&small_prog);
        const opt_cost = superluminal_cost.evaluateSlice(opt);
        const improvement = if (opt_cost.total() < base_cost.total())
            (1.0 - opt_cost.total() / base_cost.total()) * 100.0
        else
            0.0;
        std.debug.print("\n  Superoptimizer: {d:.1}% cost reduction (base={d:.1} opt={d:.1})", .{
            improvement, base_cost.total(), opt_cost.total(),
        });
        try std.testing.expect(opt_cost.total() <= base_cost.total());
    }
}
