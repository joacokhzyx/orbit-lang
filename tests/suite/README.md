# Language Behavior Suite

This directory holds small programs that verify what the fixed-point compiler does. Each file defines `fn main() -> int`; the exit code is the assertion read by `scripts/test_suite.py`. Keep each test focused on one behavior — small files catch regressions faster.

## Current Coverage

| Area | Tests |
|---|---|
| Arithmetic and unary operators | `arith.orb`, `unary_neg.orb` |
| Boolean operators and branches | `bool_and_or.orb`, `if_branch.orb` |
| Strings | `strings_eq.orb`, `strings_concat.orb`, `strings_escape.orb` |
| Loops and control flow | `while_counter.orb`, `while_break.orb`, `nesting_legal.orb` |
| Functions | `fn_recursive.orb` |
| System telemetry builtins | `system_telemetry.orb` |
| Imports and module resolution | `imports.orb`, `imports.support.orb` |
| Result construction and returns | `result_values.orb` |
| Result propagation | `result_try.orb` |
| Result handling | `result_catch.orb` |
| Error payload binding | `result_bind.orb` |
| Models and mutation | `model_fields.orb`, `model_two_fields.orb`, `model_mutation.orb` |
| Source encoding | `bom_utf8.orb` |

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

- imports and module resolution;
- `catch` blocks for `Result` errors;
- HTTP routes and request access;
- database operations and migrations;
- authentication and authorization;
- malformed-input diagnostics;
- arena isolation and resource cleanup.

Those areas should be added incrementally after the corresponding language or runtime contracts are defined.
