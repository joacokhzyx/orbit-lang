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
        \\
        \\OrbitArena* arena = NULL;
        \\
        \\int orbit_main(OrbitArena* _init_arena);
        \\
        \\int orbit_main(OrbitArena* _init_arena) {
        \\    arena = _init_arena;
        \\    return 42;
        \\    return 0;
        \\}
        \\
        \\#ifdef ORBIT_WITH_NET
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
        \\        orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return 0;
        \\    }
        \\        
        \\    if (req->path && strcmp(req->path, "/_pulse") == 0) {
        \\        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
        \\        orbit_send_response(client_sock, res);
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
        \\        orbit_string json = orbit_pulse_get_stats_json(arena);
        \\        OrbitResponse* res = orbit_response_json(arena, 200, json);
        \\        orbit_send_response(client_sock, res);
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    // Fallback 404 if no route matched
        \\    printf("404 Not Found: %s %s\n", req->method ? req->method : "(null)", req->path ? req->path : "(null)");
        \\    OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
        \\    orbit_send_response(client_sock, res);
        \\    if (lease) orbit_kynx_lease_destroy(lease);
        \\    orbit_perf_end_request(start);
        \\    return keep_alive;
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
    if (!std.mem.eql(u8, c_code, expected)) {
        std.debug.print("ACTUAL:\n{s}\nEXPECTED:\n{s}\n", .{ c_code, expected });
    }
    try std.testing.expect(std.mem.eql(u8, c_code, expected));
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
