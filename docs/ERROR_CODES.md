# Error codes (E-codes) and finding index (F-codes)

Every diagnostic `orbit check` can print, in one place. E-codes are the
codes the compiler itself emits; F-codes are the finding IDs the negative
corpus was built from, kept here so a code and its history meet.

How to read this file: the E-code table says what each code means, where it
fires (file and function), how to fix it, and which negative case pins it.
The F-code index points each finding at the negative case header that owns
it. Gathered by reading `compiler/*.orb` (`reportErrorAt`, `ParserDiagnostic`,
`tirError`) and the headers in `tests/negative/`; no compiler code was
changed to write it.

Two renderings exist (`compiler/pipeline.orb`, `printSemaErrors`). A check
that knows the source position prints an `error[E....]:` card pointing at
the line; the rest print the one-line `Semantic error:` form with no code.
A diagnostic listed below as "uncoded" is the second kind: real rejection,
no code, pinned by substring like any other.

## E1000 — frontend re-emit of a parser diagnostic

Fires in `compiler/frontend/frontend.orb`, `appendParserDiagnostics`: every
parser diagnostic is re-emitted into the TIR module with code E1000,
keeping the parser's original message text. This is the `orbit frontend`
surface, not `orbit check` (which renders the parser's own E0301–E0304
cards). Fix hint: read the message text — it is the underlying parser
diagnostic. No negative case: the frontend gate (`scripts/frontend_gate.py`)
covers this path.

## E0130 — nesting too deep

Fires in `compiler/parser.orb`, `parseDepthGuard`: expression or statement
nesting past depth 600. Fix hint: break the expression into named
intermediate values. No negative case pins it.

## E0301 — unexpected token

Fires in `compiler/parser.orb`, `parserUnexpectedToken`, and the object-literal
`{` fallback (`parseObjectLiteralFallback`). Fix hint, from
`compiler/pipeline.orb`, `parserDiagnosticHint`: check for missing brackets,
quotes, or keywords before the flagged token. Note: the recovery-shape pins
`n19`/`n20` assert the *uncoded* `parserError` messages (`Parser error`,
`Expected '}' after block.`), not this code.

## E0302 — `if` used as a value needs `else`

Fires in `compiler/parser.orb`, `parseIf` when `wantValue` holds and no
`else` follows. Fix hint: give the `if` an `else` branch, or use it as a
statement. Pinned by `tests/negative/n43_if_value_without_else.orb`.

## E0303 — `if` has no then branch

Fires in `compiler/parser.orb` when `else` arrives with no then branch
before it. Fix hint, from `parserDiagnosticHint`: a branch beginning with
an operator needs `then` before it, as in `if n then -1 else 0`. No
negative case pins it today.

## E0304 — `if` branch must be a single expression

Fires in `compiler/parser.orb`, `parseIfBranch`, when a braceless branch
starts with a statement-only token. Fix hint: wrap statement branches in
`{ ... }`. Pinned by
`tests/negative/n44_if_branch_is_a_statement.orb`.

## E1001 — non-exhaustive match

Fires in `compiler/sema.orb`, `reportErrorAt` from the match-exhaustiveness
check. Fix hint: add a case for every variant, or a `_` arm if the
fall-through is intended. Pinned by `tests/negative/n01_union_missing_arm.orb`,
`n23_union_enum_missing_arm.orb`, `n24_union_match_in_expression.orb`, and
`n25_union_wrong_qualifier.orb`.

## E1002 — literal index out of range

Fires in `compiler/sema.orb` when a literal index into a literal string or
list receiver is past the end. Fix hint: indices run `0` to `len - 1` here;
guard a computed index with `if i < xs.len()`. Pinned by
`tests/negative/n32_at_out_of_range.orb`.

## E1003 — bad member read, bad construction, bad print arity

Fires in `compiler/sema.orb`, `reportErrorAt`, for: a model built with the
wrong spelling or arity (`Model { field: value }` literal form, one argument
per field), a field/variant read nothing declares (`Model 'Point' has no
field ...`, `'int' has no member ...`, `'Shape' has no variant ...`), and
`print` called with anything but exactly 1 argument. Fix hint is per site
(see the `reportErrorAt` hint strings at `sema.orb:433-503,2737`): spell the
member as declared, construct with one argument per field in order, print
one value. Pinned by `n05`, `n06`, `n13`, `n14`, `n15`, `n47`, `n57`, `n66`,
and `n68` (`n66`: variant arity at construction; `n68`: pattern binding
count in `match`).

## E1004 — literal zero divisor, `INT_MIN / -1`

Fires in `compiler/sema.orb` for a statically decidable bad division: a
literal `0` divisor, or dividing the most negative int by `-1` (which
overflows and faults the same way). Fix hint: guard with `if d != 0`, or
divide as floats. Pinned by
`tests/negative/n41_division_by_zero_is_not_a_diagnostic.orb`. A zero held
in a variable still reaches the hardware — that half is not done (see the
case header).

## E1005 — call argument type mismatch

Fires in `compiler/sema.orb`, `reportErrorAt` at the call site, naming the
parameter and both types. Fix hint: change the argument or the parameter's
declared type. An `int` where a `float` is declared is still accepted (the C
backend widens it). Pinned by
`tests/negative/n33_call_argument_type_unchecked.orb`,
`tests/negative/n46_list_param_takes_other_element.orb`, and
`tests/negative/n67_union_variant_payload_type.orb` (positional payload
against its declared type).

## E1006 — bad type name or binding mismatch

Fires in `compiler/sema.orb`, `reportErrorAt`, for: a pushed value that
contradicts the list's element type, a type name nothing declares (types are
lower case, or declared with `model`/`union`), a binding whose value
contradicts its annotation, a bare generic model in a signature (`Box`
with no argument — write `Box<int>`), an undeterminable generic type
parameter (`n52`), and a generic field fixed to one type by an earlier field
(`n50`). The last two point at the enclosing declaration: object literals
carry no parser position, so `checkGenericModelFields` reports against the
declaration site stamped by `checkVarDecl`/`checkConstDecl` (`valueSite`);
a literal returned directly keeps the one-line form until literal positions
exist. Fix hint: change the value or the
annotation; write the type arguments. Pinned by `n11`, `n30`, `n48`, `n49`,
`n50`, `n51`, and `n52`.

## E1007 — bad top-level declaration

Fires in `compiler/sema.orb`, `reportErrorAt`, for `var` at file scope and
for a top-level `val` whose value is not an int or bool literal (only
literals become a `#define`). Fix hint: put state inside functions.
Pinned by `tests/negative/n45_top_level_var.orb`, which pins the code
itself.

## E2001 — unknown identifier (frontend)

Fires in `compiler/frontend/lower.orb`, `lowerExpression`: a load whose
name no binding declares. This is the `orbit frontend` lowering; `orbit
check` rejects the same program through sema's uncoded `Undeclared
identifier` diagnostic (pinned by `n09`). Fix hint: declare the name before
use.

## E2002 — incompatible binary operands (frontend)

Fires in `compiler/frontend/lower.orb` when a binary expression's result
type is `unknown`. Frontend lowering only; the unknown-census counts these.
Fix hint: make both operand types agree (or bind them first).

## E2003 — invalid unary operand (frontend)

Fires in `compiler/frontend/lower.orb` when a unary expression's result
type is `unknown` (`!` needs `bool`, `-` needs `int`/`float`). Frontend
lowering only. Fix hint: apply the operator to a value of the type it
takes.

## E2004 — untypable member read (frontend)

Fires in `compiler/frontend/lower.orb` when a `.field` read cannot be
typed. Added for F-0018: loads, binary ops and unary ops had diagnostics
and member reads had none, so an untypable member reached codegen silently.
Frontend lowering only. Fix hint: read the field off a value whose type the
front end knows.

## E2005 — untypable call result (frontend)

Fires in `compiler/frontend/lower.orb` when a call's result type is
`unknown` — a call whose signature the front end does not know. Same F-0018
origin as E2004, and the larger of the two (unchecked argument types
reached codegen through it). Frontend lowering only. Fix hint: call a
declared function with the declared arity.

## E2100 / E2101 — condition must be `bool` (frontend)

Fire in `compiler/frontend/lower.orb` for `if` (E2100) and `while` (E2101)
conditions whose type is not `bool`. Frontend lowering only. Fix hint:
compare first, branch on the comparison.

## E3000 — top-level declaration cannot be lowered (frontend)

Fires in `compiler/frontend/lower.orb`, `lowerProgramToTir`, for a
top-level declaration kind the frontend does not lower. Frontend lowering
only. Fix hint: this is a frontend-coverage gap, not a program typo — file
it with the program attached.

## E3001 — expression cannot be lowered (frontend)

Fires in `compiler/frontend/lower.orb`, `lowerExpression` fallback, for an
expression kind with no lowering rule. Frontend lowering only. Fix hint:
same as E3000 — a coverage gap, file it. (The 4,190 hits cited in
KNOWN_LIMITATIONS were measured on an earlier corpus; re-run
`scripts/unknown_census.py` rather than trusting the number.)

## E3002 — frontend expected a program root

Fires in `compiler/frontend/lower.orb`, `lowerProgramToTir`, when the root
node is not a program. Frontend lowering only; unreachable from the normal
pipeline. Fix hint: none — internal invariant.

## Uncoded rejections (no E-code, still pinned)

These print the one-line `Semantic error:` form and pin a substring:

| message | case |
|---|---|
| `Cannot call 'n': it is a int, not a function` | `n12` |
| `Undeclared function: ...` | `n22` |
| `Undeclared identifier: ...` | `n09` |
| `Wrong number of arguments to ...` | `n04` |
| `Duplicate symbol` | `n21` |
| `expected int, got string` (return/binding mismatch) | `n03`, `n07`, `n16`, `n17`, `n18` |
| `Nothing declares a type named` is E1006, but `expected float, got Float` | `n34` |
| `a string cannot contain a NUL byte` | `n42` |
| `does not fit an orbit_int` | `n29` |
| `an object field cannot hold a nested ...` | `n54` |
| `ok response with error status` / `err response with success status` | `n55`, `n56` |
| `cannot interpolate a value of type` | `n02` |
| `must end the path` (multi-capture not final) / `empty multi-capture name` | `n58` |
| `for loops iterate lists` (non-list or unknown iterable) | `n59` |
| `for ranges count ints` (non-int range bound) | `n64` |
| `'model Box[T: int]' is not supported ...` | `n53` |
| `Parser error` / `Expected '}' after block.` (uncoded recovery) | `n19`, `n20` |

## F-code index

Findings are stable identifiers for defect classes. Each points at the
negative case header that owns it — the header's `// what:` comment is the
full write-up.

| finding | owns it | state |
|---|---|---|
| F-0001 — match over a union missing a variant falls through silently | `n01_union_missing_arm.orb` | fixed, pinned |
| F-0002 — lists had no element type; reads dereferenced the wrong shape | `list_mixed_element_kinds.orb`, boundary half in `n39` | fixed except the `list`-parameter boundary; that remainder is F-0009 |
| F-0004 — calling an undeclared extern reached the C step as a call to a symbol nothing declares | `n22_undeclared_function_call.orb` | fixed, pinned |
| F-0009 — a `list` parameter with no element type: reads inside the helper are untyped and crash | `n39_list_parameter_has_no_element_type.orb` | **open** — the one `known-defect:` ratchet; the gate fails the day it is rejected |
| F-0011 — capitalised/unknown type names accepted at the annotation, diagnosed late or misleadingly | `n30_capitalised_type_annotation.orb`, `n34_capitalised_type_parameter.orb` | fixed (E1006), pinned |
| F-0015 — parameter types recorded but never compared at call sites | `n33_call_argument_type_unchecked.orb` | fixed (E1005), pinned |
| F-0016 — `.at()` past the end answered 0 (the NUL byte) with no diagnostic | `n32_at_out_of_range.orb` | fixed (E1002), pinned |
| F-0018 — frontend member/call expressions with no type rule reached codegen silently | no negative case (frontend-only; E2004/E2005) | fixed in lowering |
| F-0021 — numbers in documents go stale | counts in `tests/negative/README.md` and siblings; recompute with `python scripts/negative_gate.py --compiler <orbit> --list` | process note, not a defect |
| F-0023 — literal-zero division is SIGFPE, not a diagnostic | `n41_division_by_zero_is_not_a_diagnostic.orb` | fixed for literal divisors (E1004); variable divisors still fault |
| F-0024 — `for` over a never-set dynamic field miscompiles (read answers `""`, loop walks it as a list: garbage `.len()`, segfault iteration) | `n59_for_over_unknown_field.orb` | fixed (model-field reads answer declared types; unprovable iterables are check errors) |
