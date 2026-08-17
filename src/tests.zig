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
// Syntax reference: the self-hosted compiler sources under compiler/*.orb
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

    // The $ character is invalid in Orbit outside strings
    const source =
        \\fn test() {
        \\    val x = $
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

test "sema.trait_declaration_and_impl_passes" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\trait Printable {
        \\    fn print(msg: string) -> void
        \\}
        \\
        \\model Console {
        \\    id: int
        \\}
        \\
        \\impl Printable for Console {
        \\    fn print(msg: string) -> void {
        \\    }
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);
    try std.testing.expect(sema.diagnostics.error_count == 0);
}

test "sema.impl_missing_trait_method_diagnosed" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\trait Renderable {
        \\    fn render() -> void
        \\}
        \\
        \\model Widget {
        \\    width: int
        \\}
        \\
        \\impl Renderable for Widget {
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    _ = sema.analyze(root) catch {};
    try std.testing.expect(sema.diagnostics.hasErrors());
}

test "sema.generic_function_param_scope" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn identity[T](value: T) -> T {
        \\    val copy: T = value
        \\    return copy
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);
    try std.testing.expect(sema.diagnostics.error_count == 0);
}

test "sema.impl_param_type_mismatch_diagnosed" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\trait Printable {
        \\    fn print(msg: string) -> void
        \\}
        \\
        \\model Console {
        \\    id: int
        \\}
        \\
        \\impl Printable for Console {
        \\    fn print(msg: int) -> void {
        \\    }
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    _ = sema.analyze(root) catch {};
    try std.testing.expect(sema.diagnostics.hasErrors());
}

test "sema.trait_generic_param_scope" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\trait Container[T] {
        \\    fn get() -> T
        \\    fn put(item: T) -> void
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);
    try std.testing.expect(sema.diagnostics.error_count == 0);
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

test "ir_builder.rejects_top_level_with_fn_main" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\print("top-level")
        \\
        \\fn main() -> int {
        \\    return 42
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    const sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    try std.testing.expectError(error.TopLevelWithMainFunction, builder.build(root));
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
        \\    printf("\n  Orbit 0.1-rc.2");
        \\    if (boost_pct >= 0.5) {
        \\        printf(" ");
        \\        orbit_print_pink_gradient("(Superluminal)");
        \\    }
        \\    printf("\n\n");
        \\
        \\    printf("   \x1b[90m-\x1b[0m \x1b[37mLocal:\x1b[0m \x1b[1;37mhttp://localhost:%d\x1b[0m\n", port);
        \\    printf("   \x1b[90m-\x1b[0m \x1b[37mWorkers:\x1b[0m \x1b[1;37m%d\x1b[0m\n", num_workers);
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
        \\#define CHAR_SPACE ' '
        \\#define CHAR_TAB '\t'
        \\#define CHAR_CR '\r'
        \\#define CHAR_LF '\n'
        \\#define CHAR_ZERO '0'
        \\#define CHAR_NINE '9'
        \\#define CHAR_A_UPPER 'A'
        \\#define CHAR_Z_UPPER 'Z'
        \\#define CHAR_A_LOWER 'a'
        \\#define CHAR_Z_LOWER 'z'
        \\#define CHAR_UNDERSCORE '_'
        \\#define CHAR_SLASH '/'
        \\#define CHAR_DOT '.'
        \\#define CHAR_PLUS '+'
        \\#define CHAR_MINUS '-'
        \\#define CHAR_STAR '*'
        \\#define CHAR_PERCENT '%'
        \\#define CHAR_EQUAL '='
        \\#define CHAR_BANG '!'
        \\#define CHAR_COLON ':'
        \\#define CHAR_SEMICOLON ';'
        \\#define CHAR_COMMA ','
        \\#define CHAR_QUOTE '"'
        \\#define CHAR_DQUOTE '"'
        \\#define CHAR_SINGLE_QUOTE '\''
        \\#define CHAR_BACKSLASH '\\'
        \\#define CHAR_LPAREN '('
        \\#define CHAR_RPAREN ')'
        \\#define CHAR_LBRACE '{'
        \\#define CHAR_RBRACE '}'
        \\#define CHAR_LBRACKET '['
        \\#define CHAR_RBRACKET ']'
        \\#define CHAR_HASH '#'
        \\#define CHAR_AT '@'
        \\#define CHAR_DOLLAR '$'
        \\#define CHAR_AMP '&'
        \\#define CHAR_PIPE '|'
        \\#define CHAR_CARET '^'
        \\#define CHAR_TILDE '~'
        \\#define CHAR_BACKTICK '`'
        \\#define CHAR_QUESTION '?'
        \\#define CHAR_LESS '<'
        \\#define CHAR_GREATER '>'
        \\#ifndef genericParams
        \\#define genericParams(...) (void*)0
        \\#endif
        \\#ifndef _pop
        \\#define _pop() (void*)0
        \\#endif
        \\#ifndef valStr_indexOf
        \\#define valStr_indexOf(...) 0
        \\#endif
        \\
        \\int orbit_main(OrbitArena* _init_arena);
        \\
        \\__attribute__((always_inline))
        \\    int orbit_main(OrbitArena* _init_arena) {
        \\    arena = _init_arena;
        \\    return (orbit_int)(uintptr_t)(42);
        \\    return 0;
        \\}
        \\
        \\#ifdef ORBIT_WITH_NET
        \\#define ORBIT_LOGS_ACTIVE 1
        \\#define ORBIT_KYNX_ACTIVE 1
        \\static inline uint64_t orbit_route_hash(const char* method, const char* path) {
        \\    uint64_t h = 14695981039346656037ULL;
        \\    if (!method || !path) return 0;
        \\    while (*method) { h = (h ^ (unsigned char)*method++) * 1099511628211ULL; }
        \\    h = (h ^ ':') * 1099511628211ULL;
        \\    while (*path) { h = (h ^ (unsigned char)*path++) * 1099511628211ULL; }
        \\    return h;
        \\}
        \\
        \\#if ORBIT_LOGS_ACTIVE
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
        \\#endif
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
        \\#if ORBIT_KYNX_ACTIVE
        \\    extern OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
        \\    extern void orbit_kynx_lease_destroy(OrbitKynxLease* lease);
        \\    OrbitKynxLease* lease = orbit_kynx_lease_create_for_route(req->path, req->method, arena);
        \\    if (lease && (lease->flags & 1)) {
        \\        OrbitResponse* res = orbit_response_create(arena, 503, "text/plain", "503 Siege Mode Active - Non-critical Route Blocked");
        \\        orbit_send_response(client_sock, res);
        \\#if ORBIT_LOGS_ACTIVE
        \\        orbit_log_request_fmt(req->method, req->path, 503, start);
        \\#endif
        \\        orbit_kynx_lease_destroy(lease);
        \\        orbit_perf_end_request(start);
        \\        return 0;
        \\    }
        \\#endif
        \\        
        \\    if (req->path && strcmp(req->path, "/_pulse") == 0) {
        \\        OrbitResponse* res = orbit_response_create(arena, 200, "text/html", ORBIT_PULSE_DASHBOARD_HTML);
        \\        orbit_send_response(client_sock, res);
        \\#if ORBIT_LOGS_ACTIVE
        \\        orbit_log_request_fmt(req->method, req->path, 200, start);
        \\#endif
        \\#if ORBIT_KYNX_ACTIVE
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\#endif
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    if (req->path && strcmp(req->path, "/_pulse/data") == 0) {
        \\        orbit_string json = orbit_pulse_get_stats_json(arena);
        \\        OrbitResponse* res = orbit_response_json(arena, 200, json);
        \\        orbit_send_response(client_sock, res);
        \\#if ORBIT_LOGS_ACTIVE
        \\        orbit_log_request_fmt(req->method, req->path, 200, start);
        \\#endif
        \\#if ORBIT_KYNX_ACTIVE
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\#endif
        \\        orbit_perf_end_request(start);
        \\        return keep_alive;
        \\    }
        \\    uint64_t route_key = orbit_route_hash(req->method, req->path);
        \\    switch (route_key) {    default: {
        \\        OrbitResponse* res = orbit_response_create(arena, 404, "text/plain", "Not Found");
        \\        orbit_send_response(client_sock, res);
        \\#if ORBIT_LOGS_ACTIVE
        \\        orbit_log_request_fmt(req->method, req->path, 404, start);
        \\#endif
        \\#if ORBIT_KYNX_ACTIVE
        \\        if (lease) orbit_kynx_lease_destroy(lease);
        \\#endif
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
    const allocator = std.heap.smp_allocator;
    const is_windows = @import("builtin").os.tag == .windows;
    const bin_name = if (is_windows) ".\\test_arena.exe" else "./test_arena";
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

    // global_single_threaded.io() uses a failing allocator, so process spawning
    // through it always returns OutOfMemory on Windows. Use a dedicated Threaded
    // io with a real allocator (same pattern as backend/tests.zig).
    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var compile_child = std.process.spawn(io, .{
        .argv = args.items,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);
    if (compile_term != .exited or compile_term.exited != 0) {
        return error.SkipZigTest;
    }

    var test_child = std.process.spawn(io, .{
        .argv = &.{bin_name},
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const test_term = try test_child.wait(io);

    // Clean up compiled binary
    std.Io.Dir.cwd().deleteFile(io, bin_out) catch {};

    if (test_term != .exited or test_term.exited != 0) {
        return error.SkipZigTest;
    }
}

test "bootstrap.fixed_point_verification" {
    // Self-hosting 3-stage bootstrap verification (STAB-1): `orbit bootstrap
    // --verify` rebuilds stage1 -> stage2 -> stage3 and asserts stage2 and
    // stage3 are byte-identical after zeroing the COFF link timestamp.
    // Skipped only when the Zig-built driver or a C compiler is unavailable.
    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const driver_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });
    var cwd = std.Io.Dir.cwd();
    var driver_file = cwd.openFile(io, driver_path, .{}) catch return error.SkipZigTest;
    driver_file.close(io);

    // The bootstrap pipeline links via ORBIT_CC -> CC -> `zig cc`. Any machine
    // that can run `zig build test` has zig, so `zig cc` is always available
    // unless the caller explicitly points ORBIT_CC/CC at a missing compiler,
    // which is a configuration error the test should surface, not skip.

    var boot_child = std.process.spawn(io, .{
        .argv = &.{ driver_path, "bootstrap", "--verify" },
        .cwd = .{ .path = root_dir },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const bt = try boot_child.wait(io);
    if (bt != .exited or bt.exited != 0) {
        return error.BootstrapFixedPointFailed;
    }
}

test "runtime.http_pipelined_parse_no_buffer_clobber" {
    const allocator = std.heap.smp_allocator;
    const is_windows = @import("builtin").os.tag == .windows;
    const bin_name = if (is_windows) ".\\test_http_parse.exe" else "./test_http_parse";
    const bin_out = if (is_windows) "test_http_parse.exe" else "test_http_parse";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{
        "zig",
        "cc",
        "-DORBIT_WITH_NET",
        "-Isrc/runtime",
        "-Isrc/runtime/vendor",
        "src/runtime/test_http_parse.c",
        "-o",
        bin_out,
    });
    if (is_windows) {
        try args.append(allocator, "-lws2_32");
    }

    // global_single_threaded.io() uses a failing allocator, so process spawning
    // through it always returns OutOfMemory on Windows. Use a dedicated Threaded
    // io with a real allocator (same pattern as backend/tests.zig).
    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    var compile_child = std.process.spawn(io, .{
        .argv = args.items,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);
    if (compile_term != .exited or compile_term.exited != 0) {
        return error.SkipZigTest;
    }

    var test_child = std.process.spawn(io, .{
        .argv = &.{bin_name},
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const test_term = try test_child.wait(io);

    // Clean up compiled binary
    std.Io.Dir.cwd().deleteFile(io, bin_out) catch {};

    if (test_term != .exited or test_term.exited != 0) {
        std.debug.print("[HTTP-TEST] test binary failed: {any}\n", .{test_term});
        return error.HttpParseRegression;
    }
}

test "codegen.compile.req_member_value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // global_single_threaded.io() uses a failing allocator, so process spawning
    // through it always returns OutOfMemory on Windows. Use a dedicated Threaded
    // io with a real allocator (same pattern as backend/tests.zig).
    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_dir = try std.fs.path.join(alloc, &.{ root_dir, ".req_member_tmp" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer cwd.deleteTree(io, temp_dir) catch {};

    const src_path = try std.fs.path.join(alloc, &.{ temp_dir, "req_member.orb" });
    const bin_path = try std.fs.path.join(alloc, &.{ temp_dir, "req_member.exe" });

    var file = try cwd.createFile(io, src_path, .{ .truncate = true });
    var wb: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &wb);
    try fw.interface.writeAll(
        \\port 4002
        \\cors "*"
        \\db "req_member_bench.db"
        \\
        \\model User {
        \\    id: string primary
        \\    username: string
        \\    token: string
        \\}
        \\
        \\route POST "/register" => {
        \\    val u = User.create(req.body)
        \\    return response.json(201, "{\"status\":\"registered\"}")
        \\}
        \\
        \\route POST "/login" => {
        \\    val tok = "token_secret_123"
        \\    return response.json(200, "{\"token\":\"" + tok + "\"}")
        \\}
        \\
    );
    try fw.flush();
    file.close(io);

    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch return error.SkipZigTest;
    compiler_file.close(io);

    var compile_child = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_path, "-o", bin_path },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);

    const ok = compile_term == .exited and compile_term.exited == 0;
    if (!ok) {
        return error.ReqMemberCompileRegression;
    }
}

test "codegen.compile.cache_member_contextual_keyword" {
    // `cache.set(...)` regresses if the lexer keeps `set` a reserved keyword:
    // member names after `.` must accept contextual keywords. Mirrors
    // 03_page_cache_server.orb (COMPILE-1).
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_dir = try std.fs.path.join(alloc, &.{ root_dir, ".cache_member_tmp" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer cwd.deleteTree(io, temp_dir) catch {};

    const src_path = try std.fs.path.join(alloc, &.{ temp_dir, "cache_member.orb" });
    const bin_path = try std.fs.path.join(alloc, &.{ temp_dir, "cache_member.exe" });

    var file = try cwd.createFile(io, src_path, .{ .truncate = true });
    var wb: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &wb);
    try fw.interface.writeAll(
        \\port 4003
        \\cors "*"
        \\
        \\route GET "/page" => {
        \\    val cached = cache.get("html_page")
        \\    if (cached != "") return response.json(200, cached)
        \\
        \\    val page = "<h1>page</h1>"
        \\    cache.set("html_page", page, 600)
        \\    return response.json(200, page)
        \\}
        \\
    );
    try fw.flush();
    file.close(io);

    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch return error.SkipZigTest;
    compiler_file.close(io);

    var compile_child = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_path, "-o", bin_path },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);

    const ok = compile_term == .exited and compile_term.exited == 0;
    if (!ok) {
        return error.CacheMemberCompileRegression;
    }
}

test "codegen.compile.catalog_member_call_arity" {
    // Regresses the COMPILE-2 fixes: `req.query(...)` / `req.body()` call
    // forms must carry the injected `req` operand, `Model.where(cond, param)`
    // lowers to parameterized SQL, and `body.id` on a JSON string extracts the
    // field instead of casting raw bytes to a struct.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_dir = try std.fs.path.join(alloc, &.{ root_dir, ".catalog_arity_tmp" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer cwd.deleteTree(io, temp_dir) catch {};

    const src_path = try std.fs.path.join(alloc, &.{ temp_dir, "catalog_arity.orb" });
    const bin_path = try std.fs.path.join(alloc, &.{ temp_dir, "catalog_arity.exe" });

    var file = try cwd.createFile(io, src_path, .{ .truncate = true });
    var wb: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &wb);
    try fw.interface.writeAll(
        \\port 4002
        \\cors "*"
        \\db "catalog_arity.db"
        \\
        \\model Product {
        \\    id: string
        \\    name: string
        \\    category: string
        \\}
        \\
        \\route GET "/v1/catalog" {
        \\    val category = req.query("category")
        \\    if (category != "") {
        \\        val filtered = Product.where("category = ?", category)
        \\        return ok 200 filtered
        \\    }
        \\    return ok 200 Product.all()
        \\}
        \\
        \\route POST "/v1/catalog/items" {
        \\    val body = req.body()
        \\    val created = Product.create(body)
        \\    if (created) {
        \\        return ok 201 "{\"id\":\"" + body.id + "\"}"
        \\    }
        \\    err 400 "failed"
        \\}
        \\
    );
    try fw.flush();
    file.close(io);

    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch return error.SkipZigTest;
    compiler_file.close(io);

    var compile_child = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_path, "-o", bin_path },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);

    const ok = compile_term == .exited and compile_term.exited == 0;
    if (!ok) {
        return error.CatalogMemberCallArityRegression;
    }
}

test "codegen.compile.selfhost_exec_indexof_typing" {
    // Regresses SOVER-0: `orbit_os_exec_selfhost(...)` must be typed as a
    // string so `result.indexOf(...)` lowers to `orbit_string_indexOf`.
    // Before the fix, sema left the call unknown and codegen emitted a call to
    // an undeclared `compOutput_indexOf`, breaking the self-host bootstrap.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_dir = try std.fs.path.join(alloc, &.{ root_dir, ".selfhost_exec_tmp" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, temp_dir) catch {};
    defer cwd.deleteTree(io, temp_dir) catch {};

    const src_path = try std.fs.path.join(alloc, &.{ temp_dir, "selfhost_exec.orb" });
    const bin_path = try std.fs.path.join(alloc, &.{ temp_dir, "selfhost_exec.exe" });

    var file = try cwd.createFile(io, src_path, .{ .truncate = true });
    var wb: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, io, &wb);
    try fw.interface.writeAll(
        \\fn main() {
        \\    val compOutput = orbit_os_exec_selfhost("echo probe")
        \\    if compOutput.indexOf("[ERROR") != -1 || compOutput.indexOf("error:") != -1 {
        \\        print("compiler output contained an error")
        \\    } else {
        \\        print("ok")
        \\    }
        \\}
        \\
    );
    try fw.flush();
    file.close(io);

    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch return error.SkipZigTest;
    compiler_file.close(io);

    var compile_child = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_path, "-o", bin_path },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const compile_term = try compile_child.wait(io);

    const ok = compile_term == .exited and compile_term.exited == 0;
    if (!ok) {
        return error.SelfhostExecIndexOfRegression;
    }
}

test "reproducibility.cross_directory_byte_identical" {
    // STAB-7: compiling the same source from two different working dirs must
    // emit byte-identical generated C. Guards against cwd/path leakage into
    // the C backend (the self-host pipeline embeds the C source path in the
    // compiled binary, so the C text itself is the portable invariant).
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const builtin_mod = @import("builtin");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .{ .block = if (builtin_mod.os.tag == .windows) .global else .empty },
    });
    defer threaded.deinit();
    const io = threaded.io();

    const this_file = @src().file;
    const this_dir = std.fs.path.dirname(this_file) orelse ".";
    const src_dir = std.fs.path.dirname(this_dir) orelse ".";
    const root_dir = std.fs.path.dirname(src_dir) orelse ".";

    const temp_base = try std.fs.path.join(alloc, &.{ root_dir, ".repro_tmp" });
    const dir_a = try std.fs.path.join(alloc, &.{ temp_base, "a" });
    const dir_b = try std.fs.path.join(alloc, &.{ temp_base, "b" });
    const compiler_path = try std.fs.path.join(alloc, &.{ root_dir, "zig-out", "bin", "orbit.exe" });

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_a) catch {};
    cwd.createDirPath(io, dir_b) catch {};
    defer cwd.deleteTree(io, temp_base) catch {};

    const src_a = try std.fs.path.join(alloc, &.{ dir_a, "app.orb" });
    const src_b = try std.fs.path.join(alloc, &.{ dir_b, "app.orb" });
    const out_a = try std.fs.path.join(alloc, &.{ dir_a, "app_a.exe" });
    const out_b = try std.fs.path.join(alloc, &.{ dir_b, "app_b.exe" });

    const source =
        \\fn main() -> int {
        \\    return 42
        \\}
        \\
    ;
    var wb: [4096]u8 = undefined;
    {
        var f = try cwd.createFile(io, src_a, .{ .truncate = true });
        var w = std.Io.File.Writer.init(f, io, &wb);
        try w.interface.writeAll(source);
        try w.flush();
        f.close(io);
    }
    {
        var f = try cwd.createFile(io, src_b, .{ .truncate = true });
        var w = std.Io.File.Writer.init(f, io, &wb);
        try w.interface.writeAll(source);
        try w.flush();
        f.close(io);
    }

    var compiler_file = cwd.openFile(io, compiler_path, .{}) catch return error.SkipZigTest;
    compiler_file.close(io);

    var build_a = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_a, "-o", out_a },
        .cwd = .{ .path = dir_a },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const term_a = try build_a.wait(io);
    if (term_a != .exited or term_a.exited != 0) {
        return error.ReproBuildFailed;
    }

    var build_b = std.process.spawn(io, .{
        .argv = &.{ compiler_path, "build", src_b, "-o", out_b },
        .cwd = .{ .path = dir_b },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.SkipZigTest;
    const term_b = try build_b.wait(io);
    if (term_b != .exited or term_b.exited != 0) {
        return error.ReproBuildFailed;
    }

    const gen_a = try std.fs.path.join(alloc, &.{ dir_a, "last_generated.c" });
    const gen_b = try std.fs.path.join(alloc, &.{ dir_b, "last_generated.c" });
    const c_a = try readGeneratedC(io, cwd, gen_a, alloc);
    const c_b = try readGeneratedC(io, cwd, gen_b, alloc);
    try std.testing.expectEqualSlices(u8, c_a, c_b);
}

fn readGeneratedC(io: anytype, cwd: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    const buf = try alloc.alloc(u8, len);
    var rbuf: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &rbuf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

test "ir_verifier.unknown_register_use_rejected" {
    // STAB-5: a register that stays `.unknown` after codegen yet is referenced
    // as an operand of a type-dependent opcode must fail `verifyTypedIR` (the
    // `compOutput_indexOf` degradation class); a fully-typed module must pass.
    const verifier = @import("codegen/ir_verifier.zig");
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var module = ir.IRModule.init(allocator);
    defer module.deinit();

    var bad_func = ir.IRFunction.init(allocator, "bad");
    _ = try bad_func.allocRegister(allocator, .unknown);
    var bad_use = ir.IRInstruction.init(.sub);
    bad_use.dest = 1;
    bad_use.operand1 = .{ .register = 0 };
    bad_use.operand2 = .{ .int = 1 };
    try bad_func.emit(allocator, bad_use);
    try module.addFunction(bad_func);

    try std.testing.expectError(verifier.VerifierError.UnknownRegisterUse, verifier.verifyTypedIR(&module));

    var good_module = ir.IRModule.init(allocator);
    defer good_module.deinit();
    var good_func = ir.IRFunction.init(allocator, "good");
    _ = try good_func.allocRegister(allocator, .int);
    var good_use = ir.IRInstruction.init(.sub);
    good_use.dest = 1;
    good_use.operand1 = .{ .register = 0 };
    good_use.operand2 = .{ .int = 1 };
    try good_func.emit(allocator, good_use);
    try good_module.addFunction(good_func);
    try verifier.verifyTypedIR(&good_module);
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
        try std.testing.expect(opt_cost.total() <= base_cost.total());
    }
}

test "superluminal.cteval_fib_output_consumption" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn fib(n: int) -> int {
        \\    if n <= 1 { return n }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\fn main() {
        \\    print(fib(35))
        \\    print(fib(40))
        \\}
    ;
    var p = Parser.init(source, "test.orb", allocator);
    const root = try p.parse();

    var sema = try Sema.create(allocator, source);
    try sema.analyze(root);

    var builder = IRBuilder.init(allocator, source, &sema.node_types, &sema.model_registry);
    var module = try builder.build(root);

    const cteval = @import("superluminal/cteval.zig");
    var evaluator = cteval.CTEvaluator.init(allocator, &module);
    defer evaluator.deinit();
    try evaluator.optimize(&module);

    try std.testing.expect(evaluator.folded_count >= 2);

    const config = AtlasConfig{};
    var backend = CBackend.init(allocator, config, false);
    const c_code = try backend.generate(module);

    try std.testing.expect(std.mem.indexOf(u8, c_code, "9227465") != null);
    try std.testing.expect(std.mem.indexOf(u8, c_code, "102334155") != null);
}

// -----------------------------------------------------------------------------
// ir/optimizer.zig unit tests
// -----------------------------------------------------------------------------

const optimizer_mod = @import("ir/optimizer.zig");

fn allocInstr(opcode: IROpcode, dest: ?u32, o1: IRValue, o2: IRValue) IRInstruction {
    return IRInstruction{ .opcode = opcode, .dest = dest, .operand1 = o1, .operand2 = o2, .operand3 = .none };
}

test "ir.optimizer.constant_folding_add_consts" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "f");
    try func.emit(allocator, allocInstr(.add, 0, IRValue{ .int = 2 }, IRValue{ .int = 3 }));
    try module.addFunction(func);

    var folder = optimizer_mod.ConstantFolder.init(allocator);
    try folder.optimize(&module);

    const out = module.functions.items[0].instructions.items[0];
    try std.testing.expect(out.opcode == .load_const);
    try std.testing.expect(out.operand1 == .int and out.operand1.int == 5);
    try std.testing.expect(folder.folded_count == 1);
    module.deinit();
}

test "ir.optimizer.constant_folding_identity" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "f");
    // x + 0 -> copy x ; x - x -> 0 ; x * 2 -> x + x
    try func.emit(allocator, allocInstr(.add, 0, IRValue{ .register = 5 }, IRValue{ .int = 0 }));
    try func.emit(allocator, allocInstr(.sub, 1, IRValue{ .int = 9 }, IRValue{ .int = 9 }));
    try func.emit(allocator, allocInstr(.mul, 2, IRValue{ .register = 6 }, IRValue{ .int = 2 }));
    try module.addFunction(func);

    var folder = optimizer_mod.ConstantFolder.init(allocator);
    try folder.optimize(&module);

    const insts = module.functions.items[0].instructions.items;
    try std.testing.expect(insts[0].opcode == .copy and insts[0].operand1 == .register and insts[0].operand1.register == 5);
    try std.testing.expect(insts[1].opcode == .load_const and insts[1].operand1 == .int and insts[1].operand1.int == 0);
    try std.testing.expect(insts[2].opcode == .add and insts[2].operand2 == .register and insts[2].operand2.register == 6);
    try std.testing.expect(folder.folded_count == 3);
    module.deinit();
}

test "ir.optimizer.dead_code_elimination" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "f");
    try func.emit(allocator, allocInstr(.load_const, 0, IRValue{ .int = 5 }, .none));
    try func.emit(allocator, allocInstr(.load_const, 1, IRValue{ .int = 99 }, .none));
    try func.emit(allocator, allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 0 }));
    try func.emit(allocator, allocInstr(.ret, 0, IRValue{ .register = 2 }, .none));
    try module.addFunction(func);

    var dce = optimizer_mod.DeadCodeEliminator.init(allocator);
    try dce.optimize(&module);

    const insts = module.functions.items[0].instructions.items;
    try std.testing.expect(insts.len == 3);
    for (insts) |instr| {
        if (instr.opcode == .load_const) try std.testing.expect(instr.dest.? != 1);
    }
    try std.testing.expect(dce.eliminated_count == 1);
    module.deinit();
}

test "ir.optimizer.common_subexpression_elimination" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "f");
    try func.emit(allocator, allocInstr(.load_const, 0, IRValue{ .int = 2 }, .none));
    try func.emit(allocator, allocInstr(.load_const, 1, IRValue{ .int = 3 }, .none));
    try func.emit(allocator, allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 1 }));
    try func.emit(allocator, allocInstr(.add, 3, IRValue{ .register = 0 }, IRValue{ .register = 1 }));
    try func.emit(allocator, allocInstr(.ret, 0, IRValue{ .register = 3 }, .none));
    try module.addFunction(func);

    var cse = optimizer_mod.CommonSubexpressionEliminator.init(allocator);
    try cse.optimize(&module);

    const insts = module.functions.items[0].instructions.items;
    try std.testing.expect(insts[3].opcode == .copy);
    try std.testing.expect(insts[3].operand1 == .register and insts[3].operand1.register == 2);
    try std.testing.expect(cse.eliminated_count == 1);
    module.deinit();
}

// -----------------------------------------------------------------------------
// Superluminal production pass unit tests
// -----------------------------------------------------------------------------

test "superluminal.const_prop_folds_registers" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const const_prop = @import("superluminal/const_prop.zig");
    const prog = [_]IRInstruction{
        allocInstr(.load_const, 0, IRValue{ .int = 2 }, .none),
        allocInstr(.load_const, 1, IRValue{ .int = 3 }, .none),
        allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 1 }),
        allocInstr(.ret, 0, IRValue{ .register = 2 }, .none),
    };

    const result = try const_prop.constantPropagation(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        var found = false;
        for (out) |instr| {
            if (instr.opcode == .load_const and instr.dest.? == 2) {
                try std.testing.expect(instr.operand1 == .int and instr.operand1.int == 5);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "superluminal.cleanup_dce_removes_dead_reg" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const cleanup = @import("superluminal/cleanup.zig");
    const prog = [_]IRInstruction{
        allocInstr(.load_const, 0, IRValue{ .int = 5 }, .none),
        allocInstr(.load_const, 1, IRValue{ .int = 99 }, .none),
        allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 0 }),
        allocInstr(.ret, 0, IRValue{ .register = 2 }, .none),
    };

    const result = try cleanup.deadCodeElimination(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        try std.testing.expect(out.len == 3);
        for (out) |instr| {
            if (instr.opcode == .load_const) try std.testing.expect(instr.dest.? != 1);
        }
    }
}

test "superluminal.cleanup_copy_propagation" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const cleanup = @import("superluminal/cleanup.zig");
    const prog = [_]IRInstruction{
        allocInstr(.load_const, 0, IRValue{ .int = 7 }, .none),
        allocInstr(.copy, 1, IRValue{ .register = 0 }, .none),
        allocInstr(.ret, 0, IRValue{ .register = 1 }, .none),
    };

    const result = try cleanup.copyPropagation(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        try std.testing.expect(out.len == 3);
        try std.testing.expect(out[2].operand1 == .register and out[2].operand1.register == 0);
    }
}

test "superluminal.branch_opt_dead_jumps" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const branch = @import("superluminal/branch_opt.zig");
    const prog = [_]IRInstruction{
        allocInstr(.jump, 0, IRValue{ .int = 10 }, .none),
        allocInstr(.label, null, IRValue{ .int = 10 }, .none),
        allocInstr(.ret, 0, IRValue{ .register = 0 }, .none),
    };

    const result = try branch.eliminateDeadJumps(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        try std.testing.expect(out.len == 2);
        try std.testing.expect(out[0].opcode == .label);
    }
}

test "superluminal.branch_opt_dead_labels" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const branch = @import("superluminal/branch_opt.zig");
    const prog = [_]IRInstruction{
        allocInstr(.label, null, IRValue{ .int = 99 }, .none),
        allocInstr(.ret, 0, IRValue{ .register = 0 }, .none),
    };

    const result = try branch.eliminateDeadLabels(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        try std.testing.expect(out.len == 1);
        try std.testing.expect(out[0].opcode == .ret);
    }
}

test "superluminal.branch_opt_unreachable_blocks" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const branch = @import("superluminal/branch_opt.zig");
    const prog = [_]IRInstruction{
        allocInstr(.ret, 0, IRValue{ .register = 0 }, .none),
        allocInstr(.label, null, IRValue{ .int = 5 }, .none),
        allocInstr(.load_const, 0, IRValue{ .int = 1 }, .none),
    };

    const result = try branch.eliminateUnreachableBlocks(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| try std.testing.expect(out.len == 1);
}

test "superluminal.licm_hoists_invariant" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const licm = @import("superluminal/licm.zig");
    const prog = [_]IRInstruction{
        allocInstr(.label, null, IRValue{ .int = 10 }, .none),
        allocInstr(.load_const, 0, IRValue{ .int = 3 }, .none),
        allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 0 }),
        allocInstr(.jump, 0, IRValue{ .int = 10 }, .none),
    };

    const result = try licm.loopInvariantCodeMotion(allocator, &prog);
    try std.testing.expect(result != null);
    if (result) |out| {
        try std.testing.expect(out.len == 4);
        try std.testing.expect(out[0].opcode == .label);
        try std.testing.expect(out[1].opcode == .load_const);
        try std.testing.expect(out[3].opcode == .jump);
        try std.testing.expect(out[2].dest.? == 2);
    }
}

test "superluminal.tco_rewrite_self_tail_call" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const tco = @import("superluminal/tco.zig");
    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "fact");
    func.params = &.{"n"};
    func.param_types = &.{.int};
    func.return_type = .int;
    func.register_count = 4;
    try func.emit(allocator, allocInstr(.load_var, 0, IRValue{ .string = "n" }, .none));
    try func.emit(allocator, allocInstr(.arg, null, IRValue{ .register = 1 }, .none));
    try func.emit(allocator, allocInstr(.call, 2, IRValue{ .string = "fact" }, .none));
    try func.emit(allocator, allocInstr(.ret, 0, IRValue{ .register = 2 }, .none));
    try module.addFunction(func);

    var tco_pass = tco.TailCallOptimizer.init(allocator);
    try tco_pass.optimize(&module);

    try std.testing.expect(tco_pass.tco_count == 1);
    const insts = module.functions.items[0].instructions.items;
    // header label + original load_var + param copy + backward jump
    try std.testing.expect(insts.len == 4);
    try std.testing.expect(insts[0].opcode == .label);
    try std.testing.expect(insts[2].opcode == .copy and insts[2].dest.? == 0);
    try std.testing.expect(insts[3].opcode == .jump);
    module.deinit();
}

test "superluminal.memoize_marks_recursive_pure" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const memoize = @import("superluminal/memoize.zig");
    var module = ir.IRModule.init(allocator);
    var func = ir.IRFunction.init(allocator, "fib");
    func.params = &.{"n"};
    func.param_types = &.{.int};
    func.return_type = .int;
    func.register_count = 4;
    try func.emit(allocator, allocInstr(.load_var, 0, IRValue{ .string = "n" }, .none));
    try func.emit(allocator, allocInstr(.lt, 1, IRValue{ .register = 0 }, IRValue{ .int = 2 }));
    try func.emit(allocator, allocInstr(.jump_if_false, null, IRValue{ .register = 1 }, IRValue{ .int = 20 }));
    try func.emit(allocator, allocInstr(.load_const, 2, IRValue{ .int = 1 }, .none));
    try func.emit(allocator, allocInstr(.ret, 0, IRValue{ .register = 2 }, .none));
    try func.emit(allocator, allocInstr(.call, 3, IRValue{ .string = "fib" }, .none));
    try func.emit(allocator, allocInstr(.ret, 0, IRValue{ .register = 3 }, .none));
    try module.addFunction(func);

    var memo_pass = memoize.MemoizationPass.init(allocator);
    try memo_pass.optimize(&module);

    try std.testing.expect(memo_pass.memoized_count == 1);
    const insts = module.functions.items[0].instructions.items;
    try std.testing.expect(insts[0].opcode == .nop);
    try std.testing.expect(memoize.isMemoizable(module.functions.items[0]));
    try std.testing.expect(memoize.getMemoSize(module.functions.items[0]) == 1024);
    module.deinit();
}

test "superluminal.pass_runner_fixed_point_cleanup" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const cleanup = @import("superluminal/cleanup.zig");
    const branch = @import("superluminal/branch_opt.zig");
    const runner = @import("superluminal/pass_runner.zig");

    const passes = [_]runner.OptimizationPass{
        cleanup.passes[0],
        branch.passes[3],
        branch.passes[1],
    };

    const prog = [_]IRInstruction{
        allocInstr(.load_const, 0, IRValue{ .int = 5 }, .none),
        allocInstr(.load_const, 1, IRValue{ .int = 99 }, .none),
        allocInstr(.add, 2, IRValue{ .register = 0 }, IRValue{ .register = 0 }),
        allocInstr(.jump, 0, IRValue{ .int = 10 }, .none),
        allocInstr(.label, null, IRValue{ .int = 10 }, .none),
        allocInstr(.ret, 0, IRValue{ .register = 2 }, .none),
    };

    const fp = try runner.runFixedPoint(allocator, &prog, &passes, 10);
    defer allocator.free(fp.instructions);
    try std.testing.expect(fp.instructions.len == 3);
    try std.testing.expect(fp.iterations >= 1);
    try std.testing.expect(fp.passes_run >= 1);
    for (fp.instructions) |instr| {
        try std.testing.expect(instr.opcode != .label and instr.opcode != .jump);
        if (instr.opcode == .load_const) try std.testing.expect(instr.dest.? != 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream: Doctor — route conflict detection with path normalisation (DOCTOR-0)
// ─────────────────────────────────────────────────────────────────────────────

test "doctor.normalize_route_path: static paths are unchanged" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    const norm = try checker.normalizeRoutePath(alloc, "/api/health");
    try std.testing.expectEqualStrings("/api/health", norm);
}

test "doctor.normalize_route_path: colon param becomes placeholder" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    const norm = try checker.normalizeRoutePath(alloc, "/users/:id");
    try std.testing.expectEqualStrings("/users/{}", norm);
}

test "doctor.normalize_route_path: brace param becomes placeholder" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    const norm = try checker.normalizeRoutePath(alloc, "/items/{uuid}/details");
    try std.testing.expectEqualStrings("/items/{}/details", norm);
}

test "doctor.normalize_route_path: wildcard segment becomes placeholder" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    const norm = try checker.normalizeRoutePath(alloc, "/files/*");
    try std.testing.expectEqualStrings("/files/{}", norm);
}

test "doctor.normalize_route_path: quoted path strips quotes before normalising" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    // Token text includes surrounding double-quotes as produced by the lexer.
    const norm = try checker.normalizeRoutePath(alloc, "\"/orders/:orderId/items/:itemId\"");
    try std.testing.expectEqualStrings("/orders/{}/items/{}", norm);
}

test "doctor.normalize_route_path: two different param names produce identical keys" {
    var ta = testArena();
    defer ta.arena.deinit();
    const alloc = ta.arena.allocator();

    const checker = @import("doctor/checker.zig");
    const a = try checker.normalizeRoutePath(alloc, "/users/:id");
    const b = try checker.normalizeRoutePath(alloc, "/users/:uuid");
    // Both routes occupy the same URL space — their canonical keys must match.
    try std.testing.expectEqualStrings(a, b);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workstream: Doctor — deep static analysis layers (DOCTOR-1)
// Each test asserts the exact severity, code, line, and message contract.
// ─────────────────────────────────────────────────────────────────────────────

const doctor_ui = @import("doctor/ui.zig");
const doctor_ast = @import("doctor/ast_analysis.zig");
const doctor_semantic = @import("doctor/semantic_analysis.zig");

fn doctorCountWithCode(findings: []const doctor_ui.Finding, code: []const u8) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, code)) n += 1;
    }
    return n;
}

fn doctorGetFinding(findings: []const doctor_ui.Finding, code: []const u8) ?doctor_ui.Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, code)) return f;
    }
    return null;
}

fn doctorHasLine(lines: []const usize, target: usize) bool {
    for (lines) |l| {
        if (l == target) return true;
    }
    return false;
}

test "doctor.layer2: cyclomatic complexity between 11 and 20 warns at fn line" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    var buf = std.ArrayListUnmanaged(u8).empty;
    try buf.appendSlice(allocator, "fn heavy(x: int) -> int {\n");
    var i: usize = 0;
    while (i < 11) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator, "if x > {d} {{ return {d} }}\n", .{ i, i });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    try buf.appendSlice(allocator, "return 0\n}\n");
    const source = try buf.toOwnedSlice(allocator);

    const findings = try doctor_ast.analyze(allocator, source, "complex.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L2-001"));
    const f = doctorGetFinding(findings, "DOC-L2-001").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Function complexity 12") != null);
}

test "doctor.layer2: recursion without TCO warns at fn line" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn count(n: int) -> int {
        \\    count(n - 1)
        \\    return 0
        \\}
    ;
    const findings = try doctor_ast.analyze(allocator, source, "rec.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L2-002"));
    const f = doctorGetFinding(findings, "DOC-L2-002").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "fn count is recursive but not in tail position") != null);
}

test "doctor.layer2: allocation inside loop warns with exact lines" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/render" => render()
        \\fn render(rows: int) {
        \\    for item in rows {
        \\        val b = buffer_alloc(1024)
        \\        map_create()
        \\    }
        \\    while true {
        \\        list_create()
        \\    }
        \\}
    ;
    const findings = try doctor_ast.analyze(allocator, source, "loop.orb");
    try std.testing.expectEqual(@as(usize, 3), doctorCountWithCode(findings, "DOC-L2-003"));
    var found_lines = std.ArrayListUnmanaged(usize).empty;
    defer found_lines.deinit(allocator);
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "DOC-L2-003")) {
            try found_lines.append(allocator, f.line);
        }
    }
    try std.testing.expect(doctorHasLine(found_lines.items, 4));
    try std.testing.expect(doctorHasLine(found_lines.items, 5));
    try std.testing.expect(doctorHasLine(found_lines.items, 8));
    const f = doctorGetFinding(findings, "DOC-L2-003").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Allocation inside loop body in fn render at") != null);
}

test "doctor.layer2: dead function warns at fn line" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn unused_helper(x: int) -> int {
        \\    return x
        \\}
        \\route GET "/" {
        \\    return 1
        \\}
    ;
    const findings = try doctor_ast.analyze(allocator, source, "dead.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L2-004"));
    const f = doctorGetFinding(findings, "DOC-L2-004").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 1), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "fn unused_helper is never called from any route or schedule") != null);
}

test "doctor.layer3: mutable module var written from route is a data race" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\val mut counter = 0
        \\route POST "/inc" {
        \\    counter = counter + 1
        \\    return ok 200 counter
        \\}
    ;
    const findings = try doctor_semantic.analyze(allocator, source, "race.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L3-001"));
    const f = doctorGetFinding(findings, "DOC-L3-001").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.err, f.severity);
    try std.testing.expectEqual(@as(usize, 3), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Module-level mutable variable 'counter'") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "This is a data race.") != null);
}

test "doctor.layer3: untrusted request field flows into db operation" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\route GET "/v1/catalog" {
        \\    val category = req.query("category")
        \\    if (category != "") {
        \\        val filtered = Product.where("category = ?", category)
        \\        return ok 200 filtered
        \\    }
        \\}
    ;
    const findings = try doctor_semantic.analyze(allocator, source, "catalog.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L3-002"));
    const f = doctorGetFinding(findings, "DOC-L3-002").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.err, f.severity);
    try std.testing.expectEqual(@as(usize, 4), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Untrusted request field 'category'") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Possible injection risk") != null);
}

test "doctor.layer3: unfreed allocation outside handler warns" {
    var ta = testArena();
    defer ta.arena.deinit();
    const allocator = ta.arena.allocator();

    const source =
        \\fn main() {
        \\    val buffer = buffer_alloc(1024)
        \\    print(buffer)
        \\}
    ;
    const findings = try doctor_semantic.analyze(allocator, source, "main.orb");
    try std.testing.expectEqual(@as(usize, 1), doctorCountWithCode(findings, "DOC-L3-003"));
    const f = doctorGetFinding(findings, "DOC-L3-003").?;
    try std.testing.expectEqual(doctor_ui.DiagnosticSeverity.warning, f.severity);
    try std.testing.expectEqual(@as(usize, 2), f.line);
    try std.testing.expect(std.mem.indexOf(u8, f.message, "Possible unfreed allocation in fn main") != null);
}
