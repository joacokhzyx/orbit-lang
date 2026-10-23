# Error codes (E-codes) and finding index (F-codes)

Every diagnostic `orbit check` can print, in one place. E-codes are the
codes the compiler itself emits. F-codes are the finding IDs the negative
corpus was built from, kept here so a code and its history meet.

How to read this file: the E-code table says what each code means, where it
fires (file and function), how to fix it, and which negative case pins it.
The F-code index points each finding at the negative case header that owns
it. Gathered by reading `compiler/**/*.orb` (`reportErrorAt`, `ParserDiagnostic`,
`tirError`) and the headers in `tests/negative/`. No compiler code was
changed to write it.

Two renderings exist (`compiler/host/pipeline.orb`, `printSemaErrors`). A check
that knows the source position prints an `error[E....]:` card pointing at
the line. The rest print the one-line `Semantic error:` form with no code.
A diagnostic listed below as "uncoded" is the second kind: real rejection,
no code, pinned by substring like any other.

## E1000 — frontend re-emit of a parser diagnostic

Fires in `compiler/tir/entry.orb`, `appendParserDiagnostics`: every
parser diagnostic is re-emitted into the TIR module with code E1000,
keeping the parser's original message text. This is the `orbit frontend`
command, not `orbit check` (which renders the parser's own E0301–E0304
cards). Fix hint: read the message text — it is the underlying parser
diagnostic. No negative case: the frontend gate (`scripts/frontend_gate.py`)
covers this path.

## E0130 — nesting too deep

Fires in `compiler/front/parser.orb`, `parseDepthGuard`: expression or statement
nesting past depth 600. Fix hint: break the expression into named
intermediate values. No negative case pins it.

## E0301 — unexpected token

Fires in `compiler/front/parser.orb`, `parserUnexpectedToken`, and the object-literal
`{` fallback (`parseObjectLiteralFallback`). Fix hint, from
`compiler/host/pipeline.orb`, `parserDiagnosticHint`: check for missing brackets,
quotes, or keywords before the flagged token. Note: the recovery cases
`n19`/`n20` assert the *uncoded* `parserError` messages (`Parser error`,
`Expected '}' after block.`), not this code.

## E0302 — `if` used as a value needs `else`

Fires in `compiler/front/parser.orb`, `parseIf` when `wantValue` holds and no
`else` follows. Fix hint: give the `if` an `else` branch, or use it as a
statement. Pinned by `tests/negative/n43_if_value_without_else.orb`.

## E0303 — `if` has no then branch

Fires in `compiler/front/parser.orb` when `else` arrives with no then branch
before it. Fix hint, from `parserDiagnosticHint`: a branch beginning with
an operator needs `then` before it, as in `if n then -1 else 0`. No
negative case pins it today.

## E0304 — `if` branch must be a single expression

Fires in `compiler/front/parser.orb`, `parseIfBranch`, when a braceless branch
starts with a statement-only token. Fix hint: wrap statement branches in
`{ ... }`. Pinned by
`tests/negative/n44_if_branch_is_a_statement.orb`.

## E1001 — non-exhaustive match

Fires in `compiler/front/sema.orb`, `reportErrorAt` from the match-exhaustiveness
check. Fix hint: add a case for every variant, or a `_` arm if the
fall-through is intended. Pinned by `tests/negative/n01_union_missing_arm.orb`,
`n23_union_enum_missing_arm.orb`, `n24_union_match_in_expression.orb`, and
`n25_union_wrong_qualifier.orb`.

## E1002 — literal index out of range

Fires in `compiler/front/sema.orb` when a literal index into a literal string or
list receiver is past the end. Fix hint: indices run `0` to `len - 1` here.
Guard a computed index with `if i < xs.len()`. Pinned by
`tests/negative/n32_at_out_of_range.orb`.

## E1003 — bad member read, bad construction, bad print arity

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for a model built with the
wrong spelling or arity (`Model { field: value }` literal form, one argument
per field). It also fires for a field or variant read that nothing declares
(`Model 'Point' has no field ...`, `'int' has no member ...`,
`'Shape' has no variant ...`), and for `print` called with anything but exactly
1 argument. Fix hint is per site
(see the `reportErrorAt` hint strings at `sema.orb:433-503,2737`): spell the
member as declared, construct with one argument per field in order, print
one value. Pinned by `n05`, `n06`, `n13`, `n14`, `n15`, `n47`, `n57`, `n66`,
`n68`, and `n78` (`n66`: variant arity at construction; `n68`: pattern binding
count in `match`; `n78`: `res.header`/`res.cookie` take exactly 2). The same
code covers `ok` and `err` built with the wrong number of positions: `ok` takes
exactly one value, and `err` takes a message and an optional code, which is the
grammar in `docs/LANGUAGE_REFERENCE.md`. Before that check both answered
`result` before their argument count was looked at. Pinned by
`tests/negative/n97_result_no_value.orb` (`ok()`).

## E1004 — literal zero divisor, `INT_MIN / -1`

Fires in `compiler/front/sema.orb` for a statically decidable bad division: a
literal `0` divisor, or dividing the most negative int by `-1` (which
overflows and faults the same way). Fix hint: guard with `if d != 0`, or
divide as floats. Pinned by
`tests/negative/n41_division_by_zero_is_not_a_diagnostic.orb`. A zero held
in a variable still reaches the hardware — that half is not done (see the
case header).

## E1005 — call argument type mismatch

Fires in `compiler/front/sema.orb`, `reportErrorAt` at the call site, naming the
parameter and both types. Fix hint: change the argument or the parameter's
declared type. An `int` where a `float` is declared is still accepted (the C
backend widens it). Pinned by
`tests/negative/n33_call_argument_type_unchecked.orb`,
`tests/negative/n46_list_param_takes_other_element.orb`,
`tests/negative/n67_union_variant_payload_type.orb` (positional payload
against its declared type), `tests/negative/n69_generic_incoherent_arguments.orb`
(coherence across a generic call's positions), and
`tests/negative/n75_fn_value_arg_type.orb` (an argument against the signature
a function value carries).

## E1006 — bad type name or binding mismatch

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for a pushed value that
contradicts the list's element type. It also fires for a type name nothing
declares (types are lower case, or declared with `model`/`union`), and for a
binding whose value contradicts its annotation. Also a bare generic model in a
signature (`Box` with no argument — write `Box<int>`), an undeterminable
generic type parameter (`n52`), and a generic field fixed to one type by an
earlier field (`n50`). The last two point at the enclosing declaration:
object literals carry no parser position, so `checkGenericModelFields` reports
against the declaration site stamped by `checkVarDecl`/`checkConstDecl`
(`valueSite`). A literal returned directly keeps the one-line form until
literal positions exist. Fix hint: change the value or the
annotation. Write the type arguments. Pinned by `n11`, `n30`, `n48`, `n49`,
`n50`, `n51`, `n52`, and `n70` (`n70`: a generic function's parameter no
argument can fix).

## E1007 — bad top-level declaration

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for `var` at file scope and
for a top-level `val` whose value is not an int or bool literal (only
literals become a `#define`). Fix hint: put state inside functions.
Pinned by `tests/negative/n45_top_level_var.orb`, which pins the code
itself.

## E1008 — bad `port` config declaration

Fires in `compiler/front/sema.orb`, `checkConfigDecl`, for a top-level `port`
declaration whose value is not an integer literal, or is one outside
1..65535. `port` is read: the value becomes the default port the generated
server binds when no `argv[1]` port is given, so a value that is not a port
would put the service somewhere the file does not name. Expressions are
refused, not evaluated — the port is fixed when the program is compiled and
the reader never runs, so an undeclared name inside the value is not
diagnosed as an unknown identifier. Fix hint: write the number directly,
e.g. `port 8080`. Pick a port between 1 and 65535. Pinned by
`tests/negative/n81_port_string.orb` (a string), `n82_port_zero.orb` (out of
range), and `n83_port_not_literal.orb` (an expression).

## E1009 — bad assignment target

Fires in `compiler/front/sema.orb`, `checkAssignmentTarget`, for the target of
an assignment. A bare-name target has to name a declared binding, that binding
has to be mutable, and the value has to agree with its declared type. A `val`
is bound once; a store into it is refused instead of writing the second value.
A name nothing declares is refused before the builder, which used to invent a C
variable and drop the store. An `int` into an enum-typed binding is accepted:
the C slot is an int, and the formatter stores token tags through int fields.

A member or index target is checked against the declaration that owns the
slot. `p.x = "s"` where `P.x` is declared `int` reports
`Cannot store string in field 'P.x': it is declared int.`. A field the model
does not declare reports `Model 'P' has no field 'y'.`, the same message a
read of that field gets. `xs[0] = "s"` where `xs` is `list<int>` reports
`Cannot store string in list<int>: the element is int.`. A receiver that is
`unknown`, a bare `list`, or a string stays unchecked: there is no declaration
to hold the value against, and refusing it would turn a gap in inference into
an error at the store. An enum value into an `int` field, or an `int` into an
enum-typed field, is accepted: an enum's C representation is an int, so the
two round-trip. Fix hint: declare the name with `var`, or
assign a value of the declared type. Pinned by
`tests/negative/n90_val_reassignment.orb` (a `val` store),
`n91_assignment_type_mismatch.orb` (a string into an `int`),
`n92_assignment_target_undeclared.orb` (a name nothing declares),
`n93_member_store_string.orb` (a string into an `int` field),
`n94_index_store_string.orb` (a string into a `list<int>` slot),
`n95_member_store_unknown_field.orb` (a field the model does not declare), and
`n96_member_store_float.orb` (a float into an `int` field).

## E1010 - a `result` value is discarded

Fires in `compiler/front/sema.orb`, `checkDiscardedResult`, for a statement
whose type is `result`: a call that can fail, whose answer nothing reads. A
failure is reported by the value and nothing in the runtime logs it, so the
program exits 0 while the write, fetch or parse the call stood for did not
happen. Every statement a block walks is checked. The last statement of an `if`
branch and of a `match` case is that branch's value, so a `result` there is
consumed by whatever reads the branch (`val r = if c { ok(1) } else { err("x") }`
is accepted). Fix hint: bind it with `val r = ...` and read it with
`try r catch`, `match` on it, or return it from a `-> result` function. The
message names the callee when the statement is a call; a statement of another
shape (a bare name, an `if` used as a statement) has no position in the AST and
prints the one-line form without the code. Pinned by
`tests/negative/n98_result_discarded.orb`.

## E2001 - unknown identifier (frontend)

Fires in `compiler/tir/lower.orb`, `lowerExpression`: a load whose
name no binding declares. This is the `orbit frontend` lowering. `orbit
check` rejects the same program through sema's uncoded `Undeclared
identifier` diagnostic (pinned by `n09`). Fix hint: declare the name before
use.

## E2002 — incompatible binary operands (frontend)

Fires in `compiler/tir/lower.orb` when a binary expression's result
type is `unknown`. Frontend lowering only. The unknown-census counts these.
Fix hint: make both operand types agree (or bind them first).

## E2003 — invalid unary operand (frontend)

Fires in `compiler/tir/lower.orb` when a unary expression's result
type is `unknown` (`!` needs `bool`, `-` needs `int`/`float`). Frontend
lowering only. Fix hint: apply the operator to a value of the type it
takes.

## E2004 — untypable member read (frontend)

Fires in `compiler/tir/lower.orb` when a `.field` read cannot be
typed. Added for F-0018: loads, binary ops and unary ops had diagnostics
and member reads had none, so an untypable member reached codegen silently.
Frontend lowering only. Fix hint: read the field off a value whose type the
front end knows.

## E2005 — untypable call result (frontend)

Fires in `compiler/tir/lower.orb` when a call's result type is
`unknown` — a call whose signature the front end does not know. Same F-0018
origin as E2004, and the larger of the two (unchecked argument types
reached codegen through it). Frontend lowering only. Fix hint: call a
declared function with the declared arity.

## E2100 / E2101 — condition must be `bool` (frontend)

Fire in `compiler/tir/lower.orb` for `if` (E2100) and `while` (E2101)
conditions whose type is not `bool`. Frontend lowering only. Fix hint:
compare first, branch on the comparison.

## E3000 — top-level declaration cannot be lowered (frontend)

Fires in `compiler/tir/lower.orb`, `lowerProgramToTir`, for a
top-level declaration kind the frontend does not lower. Frontend lowering
only. Fix hint: this is a frontend-coverage gap, not a program typo — file
it with the program attached.

## E3001 — expression cannot be lowered (frontend)

Fires in `compiler/tir/lower.orb`, `lowerExpression` fallback, for an
expression kind with no lowering rule. Frontend lowering only. Fix hint:
same as E3000 — a coverage gap, file it. (The 4,190 hits cited in
KNOWN_LIMITATIONS were measured on an earlier corpus. Re-run
`scripts/unknown_census.py` rather than trusting the number.)

## E3002 — frontend expected a program root

Fires in `compiler/tir/lower.orb`, `lowerProgramToTir`, when the root
node is not a program. Frontend lowering only, and unreachable from the normal
pipeline. Fix hint: none — internal invariant.

## Uncoded rejections (no E-code, still pinned)

These print the one-line `Semantic error:` form and pin a substring:

| message | case |
|---|---|
| `Cannot call 'n': it is a int, not a function` | `n12` |
| `Undeclared function: ...` | `n22` |
| `Undeclared identifier: ...` | `n09` |
| `Wrong number of arguments to ...` | `n04`, `n74` (`n74`: through a function value) |
| `Cannot use generic function ... as a value` | `n76` |
| `Cannot use 'main' as a value` | `n77` |
| `Duplicate symbol` | `n21` |
| `expected int, got string` (return/binding mismatch) | `n03`, `n07`, `n16`, `n17`, `n18`, `n99` (`n99`: a `-> result` body returns an int) |
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
| `'fn f[T: int]' is not supported ...` | `n71` |
| `'async fn' is not supported ...` | `n72` |
| `'every' schedules are not supported ...` | `n73` |
| `Variant 'Both' declares 2 payloads ...` / `Pattern binds 1 names ...` | `n66`, `n68` |
| `Payload 2 of 'Both' is declared ...` | `n67` |
| `bitwise '<op>' takes two ints, not ...` (`&`, `\|`, `^`, `<<`, `>>`) | `n79` |
| `bitwise '~' takes one int, not ...` | `n80` |
| `Parser error` / `Expected '}' after block.` (uncoded recovery) | `n19`, `n20` |

## F-code index

Findings are stable identifiers for defect classes. Each points at the
negative case header that owns it — the header's `// what:` comment is the
full write-up.

| finding | owns it | state |
|---|---|---|
| F-0001 — match over a union missing a variant falls through silently | `n01_union_missing_arm.orb` | fixed, pinned |
| F-0002 — lists had no element type; reads dereferenced the wrong type | `list_mixed_element_kinds.orb`, boundary half in `n39` | fixed, including the `list`-parameter boundary (F-0009): helpers spell `list<T>` and each call site compiles its own proven instance |
| F-0004 — calling an undeclared extern reached the C step as a call to a symbol nothing declares | `n22_undeclared_function_call.orb` | fixed, pinned |
| F-0009 — a `list` parameter with no element type: reads inside the helper are untyped and crash | `n39_list_parameter_has_no_element_type.orb` (now the generic form, refusing the incoherent call) | fixed (generic functions: `n39` pins the coherence refusal; `generic_functions.orb` + `std_lists_generic.orb` prove the sound spelling; a bare `list` stays lenient for dynamic values, the way `unknown` is) |
| F-0011 — capitalised/unknown type names accepted at the annotation, diagnosed late or misleadingly | `n30_capitalised_type_annotation.orb`, `n34_capitalised_type_parameter.orb` | fixed (E1006), pinned |
| F-0015 — parameter types recorded but never compared at call sites | `n33_call_argument_type_unchecked.orb` | fixed (E1005), pinned |
| F-0016 — `.at()` past the end answered 0 (the NUL byte) with no diagnostic | `n32_at_out_of_range.orb` | fixed (E1002), pinned |
| F-0018 — frontend member/call expressions with no type rule reached codegen silently | no negative case (frontend-only; E2004/E2005) | fixed in lowering |
| F-0021 — numbers in documents go stale | counts in `tests/negative/README.md` and siblings; recompute with `python scripts/negative_gate.py --compiler <orbit> --list` | process note, not a defect |
| F-0023 — literal-zero division is SIGFPE, not a diagnostic | `n41_division_by_zero_is_not_a_diagnostic.orb` | fixed for literal divisors (E1004); variable divisors still fault |
| F-0024 — `for` over a never-set dynamic field miscompiles (read answers `""`, loop walks it as a list: garbage `.len()`, segfault iteration) | `n59_for_over_unknown_field.orb` | fixed (model-field reads answer declared types, and unprovable iterables are check errors) |
| F-0025 - assignment target is never checked: a `val` store, a type mismatch, and an undeclared name all pass `check` | `n90_val_reassignment.orb`, `n91_assignment_type_mismatch.orb`, `n92_assignment_target_undeclared.orb` | fixed (E1009), pinned |
