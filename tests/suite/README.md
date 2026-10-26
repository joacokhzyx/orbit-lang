# Language Behavior Suite

This directory holds small programs that verify what the fixed-point compiler does. Each file defines `fn main() -> int`; the exit code is the assertion read by `scripts/test_suite.py`. Keep each test focused on one behavior - small files catch regressions faster.

## Current Coverage

| Area | Tests |
|---|---|
| Arithmetic and unary operators | `arith.orb`, `unary_neg.orb` |
| Bitwise and shift operators | `bitwise_operators.orb` |
| Boolean operators and branches | `bool_and_or.orb`, `if_branch.orb` |
| Strings | `strings_eq.orb`, `strings_concat.orb`, `strings_escape.orb` |
| Loops and control flow | `while_counter.orb`, `while_break.orb`, `nesting_legal.orb` |
| Functions | `fn_recursive.orb` |
| System telemetry builtins | `system_telemetry.orb` |
| Imports and module resolution | `imports.orb`, `imports.support.orb` |
| Result construction and returns | `result_values.orb` |
| Result propagation | `result_try.orb` |
| Result handling | `result_catch.orb` |
| Result bound to a val or passed as an argument | `result_bind.orb`, `result_binding.orb` |
| Models and mutation | `model_fields.orb`, `model_two_fields.orb`, `model_mutation.orb` |
| Field and element stores | `member_and_index_store.orb` |
| Integer literals (hex, separators) | `integer_literals.orb` |
| Raw strings, triple-quoted | `raw_string_literals.orb` |
| String interpolation | `interpolation.orb` |
| Constant folding and its limits | `peephole_folds.orb`, `peephole_no_fold_side_effects.orb`, `peephole_int_bool_only.orb` |
| Arena lifetime | `arena_sink_scope.orb` |
| Source encoding | `bom_utf8.orb` |
| Models passed, returned and nested | `model_param_return.orb`, `model_nested.orb` |
| Models with list fields and lists of models | `model_list_field.orb`, `model_list_of_models.orb` |
| Many short-lived models | `model_alloc_loop.orb` |
| Union payloads and match | `union_payload_return.orb`, `union_model_payload.orb`, `union_nested_match.orb` |
| Enumerations | `enum_values.orb` |
| Result chains, messages and loops | `result_chain.orb`, `result_message.orb`, `result_in_loop.orb`, `result_string_value.orb`, `result_catch_binding_scope.orb` |
| Function values chosen at run time | `fn_value_dispatch.orb` |
| String scanning, building and comparison | `string_scan.orb`, `string_builder_loop.orb`, `string_compare_order.orb` |
| Generic functions over lists | `generic_multi.orb` |
| 32-bit integer wrap and float arithmetic | `int_wrap_32.orb`, `float_accumulate.orb` |
| Recursion | `recursion_mix.orb` |
| Large lists, stacks, queues, sorting | `list_large_loop.orb`, `list_stack_queue.orb` |
| Compiler-style programs | `mini_parser.orb`, `parallel_lists_table.orb` |
| List fields read through a model built by constructor call | `model_ctor_list_field_read.orb` |
| User functions named like compiler helpers or string methods | `user_fn_named_check.orb`, `user_fn_named_find.orb` |

## Running

Build a fixed-point compiler, then run the suite:

```sh
python scripts/verify_seed.py --cc "$CC" --emit-fixed-point /tmp/orbit_fp
python scripts/test_suite.py --cc "$CC" --compiler /tmp/orbit_fp
```

The runner reports the number of successful programs and fails when a program cannot compile, times out, or exits with an unexpected code.

## Adding a Test

- Keep the program focused on one language behavior.
- Name helper modules with the `.support.orb` suffix so the suite runner does not execute them as standalone tests.
- Use the exit code as the assertion result.
- Add the file to the coverage table above.
- Prefer a regression test for a previously observed compiler or runtime defect.
- Run the fixed-point, parity, and suite gates before submitting the change.

## Coverage Gaps

The current behavior suite does not yet provide dedicated executable coverage for:

- HTTP routes and request access;
- database operations and migrations;
- authentication and authorization;
- malformed-input diagnostics;
- arena isolation and resource cleanup.

Those areas should be added incrementally after the corresponding language or runtime contracts are defined.
