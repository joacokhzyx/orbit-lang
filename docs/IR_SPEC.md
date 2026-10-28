# IRv1 — Orbit IR Specification (language side)

- **Language pin:** `5c01cea68f125f06dd3ac82a61776827bdb0c6f3`
- **Status:** language-side proposal for R6. It is not a normative
  publication of the Orbit repo: at this pin there is no `--emit-ir`, no
  versioned IR spec, and no serialized IR corpus.
- **Relation to the external draft:** `C:/Users/Usuario/Downloads/orbit-r6/docs/IR_SPEC_DRAFT.md`
  was used as a proposal and has been verified claim by claim against
  `compiler/ir/ir.orb`, `compiler/ir/builder.orb`, `compiler/emit/c_backend.orb`,
  `compiler/emit/route_runtime.orb`, `compiler/ir/cteval.orb` and `runtime/orbit_api.h`.
  Where this document and the draft disagree, this document prevails. Where
  the language publishes something else, the language prevails.
- **Gap rule:** everything marked `UNSPECIFIED` must fail in the loader with
  a diagnostic identifying the opcode/field. No approximating, no shims,
  no invented semantics.

## 1. Opcode inventory (66)

Defined in `compiler/ir/ir.orb:3-79`, in this order (index 0–65):

| # | Opcode | # | Opcode | # | Opcode | # | Opcode |
|---|--------|---|--------|---|--------|---|--------|
| 0 | `nop` | 15 | `ge` | 30 | `db_all` | 45 | `list_pop` |
| 1 | `load_const` | 16 | `and_op` | 31 | `db_where` | 46 | `map_create` |
| 2 | `load_var` | 17 | `or_op` | 32 | `http_response` | 47 | `map_set` |
| 3 | `store_var` | 18 | `not_op` | 33 | `label` | 48 | `map_get` |
| 4 | `decl_var` | 19 | `neg` | 34 | `copy` | 49 | `map_has` |
| 5 | `add` | 20 | `begin_block` | 35 | `arg` | 50 | `map_delete` |
| 6 | `sub` | 21 | `end_block` | 36 | `load_field` | 51 | `map_keys` |
| 7 | `mul` | 22 | `call` | 37 | `store_field` | 52 | `result_ok` |
| 8 | `div` | 23 | `ret` | 38 | `switch_op` | 53 | `result_err` |
| 9 | `mod` | 24 | `jump` | 39 | `type_info` | 54 | `result_unwrap` |
| 10 | `eq` | 25 | `jump_if_false` | 40 | `list_create` | 55 | `result_is_ok` |
| 11 | `ne` | 26 | `alloc` | 41 | `list_push` | 56 | `result_unwrap_err` |
| 12 | `lt` | 27 | `free` | 42 | `list_get` | 57 | `union_create` |
| 13 | `le` | 28 | `db_get` | 43 | `list_set` | 58 | `union_get_tag` |
| 14 | `gt` | 29 | `db_set` | 44 | `list_len` | 59 | `union_get_data` |
| 60 | `bit_and` | 61 | `bit_or` | 62 | `bit_xor` | 63 | `shl` |
| 64 | `shr` | 65 | `bit_not` | | | | |

The C backend dispatches all 66 in `compiler/emit/c_backend.orb:2422-3599`. Its default
arm (`c_backend.orb:3596-3599`) emits the comment `/* Unknown opcode */` and
carries on: an IRv1 loader must turn that case into a fatal error, never into
a comment.

### 1.1 Producers observed in the builder

"Producer" means an `ir_init_instr(IROpcode.X)` site in
`compiler/ir/builder.orb`. Verified by exhaustive search:

- **With a producer in the builder:** `arg`, `call`, `decl_var`, `load_var`,
  `store_var`, `load_const`, `jump`, `jump_if_false`, `label`, `copy`, `ret`,
  `list_len`, `lt`, `list_get`, `add`, `sub`, `result_ok`, `result_err`, `eq`,
  `union_get_tag`, `union_get_data`, `load_field`, `store_field`, `list_push`,
  `list_set`, `list_pop`, `map_has`, `map_delete`, `map_keys`, `list_create`,
  `not_op`, `neg`, `mul`, `div`, `mod`, `ne`, `le`, `gt`, `ge`,
  `result_is_ok`, `result_unwrap`, `result_unwrap_err`.
  (Representative sites: `builder.orb:1218-1231` arg/call, `2606-2681`
  jumps/labels/copy, `2906-2910` and `3910-3975` collections, `3117-3192`
  results, `3285-3378` unions/fields, `4584-4597` binop table,
  `4610`/`4618` not/neg, `4831-4854` result_is_ok/unwrap/unwrap_err.)
- **With no producer in the builder (exist only in the enum + lowering):**
  `nop`, `begin_block`, `end_block`, `alloc`, `free`, `db_get`, `db_set`,
  `db_all`, `db_where`, `http_response`, `switch_op`, `type_info`,
  `map_create`, `map_set`, `map_get`, `union_create`, `and_op`, `or_op`.
  - `and_op` and `or_op` had a producer until `&&` and `||` were lowered to
    `copy`, `jump_if_false`, `jump` and `label`, so that the right operand runs
    only when the left one does not decide the result. A document that carries
    them still means C `&&` / `||` over two evaluated operands (§1.2).
  - `nop` is produced by constant folding (`compiler/ir/cteval.orb:953,998`).
  - Language-level DB access does NOT use `db_*`: it lowers through `call` to
    helpers `orbit_db_query_*` / `orbit_db_insert` / `orbit_db_update` /
    `orbit_db_delete`
    (`builder.orb:295-306`, `3585-3634`, `3838-3869`). The `db_*` opcodes have
    no producer anywhere in `compiler/**/*.orb` at this pin.
  - The map methods `.has` / `.delete` / `.keys` do emit opcodes
    (`builder.orb:4053,4063,4072`). All other map traffic lowers through
    `call` (the backend matches `orbit_map_create` on the call path,
    `c_backend.orb:773`).
  - Route HTTP responses lower through `call`, not through `http_response`.

Consequence for the loader: the 18 producer-less opcodes are syntactically
valid in IRv1 but the corpus (§5) does not exercise them. Their execution
semantics stay `UNSPECIFIED` except as fixed by the observed lowering (§1.2).

### 1.2 Observable per-opcode semantics (observed C lowering)

`O1..O3` = tagged operands, `D` = destination. Everything not fixed here is
`UNSPECIFIED` (§6). References point at the dispatch in `c_backend.orb:2422-3599`.

| Opcode | Observed lowering effect | Deciding field/condition |
|---|---|---|
| `nop` | No effect | — |
| `load_const` | `D ← O1` (`2427-2430`) | `generateValue` (§2.2) |
| `load_var` | `D ←` variable named by O1 (`2431-2484`); cast by register type and variable type; names containing `TAG_` are enum tags | `registerTypes[D]`, `variableDefType`, spellings `float`/`int`/`bool`/`result` |
| `store_var` / `decl_var` | `name(O1) = cast(value(O2))` (`2485-2494`); identical emission | `storeCastFor` |
| `add` | `orbit_string_concat(arena, a, b)` concat if either operand is a string; `orbit_float` addition if either operand is a float; else integer addition over `(uintptr_t)` (`2495-2508`) | `isStringOperand`, `operandDefType` |
| `sub` / `mul` | Float or integer subtraction/multiplication (`2509-2524`) | `operandDefType` |
| `div` / `mod` | Float division/remainder, or **signed** division/remainder over `orbit_int` (`2525-2545`, comment F-0014) | `operandDefType` |
| `eq` / `ne` | `strcmp()==0` / `!=0` if both are strings; float comparison; else equality over `(uintptr_t)` (`2546-2573`) | `isStringOperand`, `operandDefType` |
| `lt` / `le` / `gt` / `ge` | Float comparison, or **signed** comparison over `(intptr_t)` (`2582-2612`) | `operandDefType` |
| `and_op` / `or_op` / `not_op` | `&&`, `\|\|`, `!` in C (`2614-2625`). The builder emits only `not_op`; source `&&` / `\|\|` is control flow (see §1.1) | — |
| `neg` | Negation (`2626-2633`) | float or integer type |
| `bit_and` / `bit_or` / `bit_xor` | `D ← (orbit_int)(uintptr_t)(((uintptr_t)O1) OP ((uintptr_t)O2))` with `OP` = `&`, `\|`, `^`; §1.3 | operands and `D` are `int` |
| `shl` | `D ← (orbit_int)(uintptr_t)(((uintptr_t)O1) << (((uintptr_t)O2) & 31))`; §1.3 | operands and `D` are `int` |
| `shr` | `D ← (orbit_int)(uintptr_t)(((uintptr_t)O1) >> (((uintptr_t)O2) & 31))`; arithmetic for an `int` O1, §1.3 | operands and `D` are `int` |
| `bit_not` | `D ← (orbit_int)(uintptr_t)(~((uintptr_t)O1))`; §1.3 | operand and `D` are `int` |
| `begin_block` / `end_block` | Open/close `{` / `}` (`2634-2641`) | — |
| `label` | `label_N:;` only if the label is referenced (`2642-2647`) | `refLabels` |
| `jump` | `goto label_N` with O1 (`2648-2651`) | — |
| `jump_if_false` | `if (!(O1)) goto label_O2` (`2652-2655`) | — |
| `copy` | `D ← O1` (`2656-2660`); an `int` O1 into a `float` D converts the value, as C assignment does | — |
| `arg` | Without D: appends O1 to the pending `call` args. With D: Int O1 is a parameter index, `D ←` parameter name (`2661-2679`) | `dest == -1`, `params` |
| `call` | §3 (full protocol: arity in O2, aliases, `print`, indirect calls) (`2680-3190`) | O1 (name or register), O2 arity |
| `ret` | Return by `returnType`: `None` → per-type default (`0`, `0.0`, `return;`, `NULL`); register/value → cast by type (`3192-3273`); `main` → `int`, route → `OrbitResponse*` | `returnType`, name |
| `alloc` | `D ← orbit_arena_alloc(arena, O1)`; without O1, `sizeof(void*)` (`3274-3286`) | O1 size |
| `free` | Comment `/* free - arena managed */` only; never frees (`3287-3290`) | — |
| `load_field` | Field read; `.length`/`.len` on a string → `orbit_string_len` (`3291-3351`) | O1 base, O2 name (with possible `owner.` prefix via `fieldRefOwner`) |
| `store_field` | Field write (`3352-3380`) | O1 base, O2 name, O3 value |
| `list_create` | `{ OrbitResult _lr = orbit_list_create_typed(arena, sizeof(void*), O2, elemKind); D = ok ? list : NULL; }` (`3381-3387`) | O2 capacity, `elemKind` |
| `list_push` | Typed push by `elemKind` (`3388-3401`) | O1 list, O2 value, `elemKind` |
| `list_get` | `D ←` typed read by `elemKind` (`3402-3405`) | O1 list, O2 index, `elemKind` |
| `list_set` | Typed write; O2 index, O3 value (`3406-3409`) | O1 list, `elemKind` |
| `list_len` | String → `orbit_string_len`; else `(orbit_int)orbit_list_len` (`3410-3417`) | O1 |
| `list_pop` | Error when empty + read of the last element + shortening (`3418-3427`) | O1 list, `elemKind` |
| `map_create` | `D = orbit_map_create(O1)` (`3428-3431`) | O1 |
| `map_set` | `D = orbit_map_set(O1, O2, O3)` (`3432-3435`) | O1 map, O2 key, O3 value |
| `map_get` | `D = orbit_map_get(O1, O2)` (`3436-3439`) | O1 map, O2 key |
| `map_has` | `D = orbit_map_has(O1, O2)` (`3440-3443`) | O1 map, O2 key |
| `map_delete` | `D = orbit_map_delete(O1, O2)` (`3444-3447`) | O1 map, O2 key |
| `map_keys` | `D = orbit_map_keys(O1)` (`3448-3451`) | O1 map |
| `result_ok` | Float → `orbit_result_ok_float`; rest → `orbit_result_ok((void*)(uintptr_t)(O1))` (`3452-3463`) | type of O1 |
| `result_err` | O2 `None` → `orbit_result_err(code(O1))`; else → `orbit_result_err(code(O2), message(O1))` (`3464-3477`) | O1 message, O2 code |
| `result_unwrap` | Float destination → `orbit_result_get_float(O1)`; int, bool, string or list destination → `O1.value` cast to the destination; else → `O1.value` (`3478-3498`) | `registerTypes[D]` |
| `result_unwrap_err` | `O1.error_msg ? O1.error_msg : ""` (`3499-3502`) | O1 |
| `result_is_ok` | `D = O1.ok` (`3503-3506`) | O1 |
| `union_create` | Allocates `orbit_alloc(arena, 16)`, stores tag (int) + data (pointer) (`3507-3510`) | O1 tag, O2 data |
| `union_get_tag` / `union_get_data` | Read of `.tag` / `.data` of the `{int tag; void* data;}` layout (`3511-3518`) | O1 union |
| `switch_op` | `switch (O1) {` or a comment when O1 is empty (`3519-3528`) | O1 |
| `type_info` | Comment `/* type_info */` only (`3529-3532`) | — |
| `db_get` | `D = orbit_db_get(O1[, O2])` (`3533-3547`) | O1, O2 |
| `db_set` | `D = orbit_db_set(O1[, O2[, O3]])` (`3548-3566`) | O1, O2, O3 |
| `db_all` | `D = orbit_db_all(O1)` (`3567-3576`) | O1 |
| `db_where` | `D = orbit_db_where(O1[, O2])` (`3577-3591`) | O1, O2 |
| `http_response` | `ORBIT_API_RESPONSE(O1, O2, O3)` (`3592-3595`) | O1, O2, O3 |

### 1.3 Bitwise and shift opcodes

Source operators: `&` `bit_and`, `|` `bit_or`, `^` `bit_xor`, `<<` `shl`,
`>>` `shr`, unary `~` `bit_not`. They follow `union_get_data` in the
`IROpcode` union, so no earlier index moved. The builder emits a binary one
as `D, O1, O2` and `bit_not` as `D, O1`. `D` is `int`. The verifier
(`verifybitwiseBinop`) rejects an operand or destination whose type is known
and is not `int`. The C backend lowers them at `c_backend.orb:2746-2778`,
and `generateRegAssign` narrows the result to `orbit_int`, a 32-bit signed
integer:

- **Width.** Each operand is cast to `uintptr_t` (64 bits on both x86-64
  targets) from its 32-bit `int` register, so a negative operand is
  sign-extended. The 64-bit result is cast to `orbit_int`: the low 32 bits,
  two's complement.
- **`bit_and`, `bit_or`, `bit_xor`, `bit_not`.** Bitwise on the 32-bit
  pattern. `~0` is `-1`; `~x` is `-x - 1`.
- **`shl`.** The count is `O2 & 31`, so a count of 32 or more wraps and a
  negative count takes its low 5 bits. `1 << 33` is `2`, `1 << 31` is
  `-2147483648`. Bits shifted past bit 31 disappear in the narrowing.
- **`shr`.** The shift runs on the 64-bit sign-extended pattern, so it is
  arithmetic: `-8 >> 1` is `-4` and `-1 >> 31` is `-1`. No logical right
  shift exists. The count is `O2 & 31`.
- **No trap.** Every operand and count has a defined result, and no overflow
  check exists.

### 1.4 `load_field` on an `object` register

A register typed `object` holds an `OrbitObject*` made by
`orbit_object_create` (§3.3). A `load_field` whose O1 is such a register is a
keyed lookup, not a struct member read. O2 is the key. A `Sym` O2 is the
written form `o.name`; a `String` O2 is the written form `o.get("name")`.
The C backend treats both the same: it takes the text of either. A
`Register` O2 (`o.get(k)` with a non-literal `k`) has no text, and the
backend looks up the key `""`. A consumer rejects that form.

The destination type names the getter, and the getter is the runtime call:

| Destination type | Runtime getter | Result |
|---|---|---|
| `int` | `orbit_object_get_int` | `orbit_int` |
| `float` | `orbit_object_get_float` | `orbit_float` |
| `bool` | `orbit_object_get_bool` | `orbit_bool` |
| `string` | `orbit_object_get_string` | `const char*` |
| `object` | `orbit_object_get_object` | `OrbitObject*` |
| `list` | `orbit_object_get_list` | `const OrbitList*` |

A key the object never stored gives the zero of the getter's kind: `0`,
`0.0`, `false`, `""`, and `NULL` for `object` and `list`
(`runtime/json.c:227-270`). A key stored with another kind gives the same
zero, not a conversion. The destination type comes from the
`orbit_object_set_*` calls on that key in the same function; when the
function has none, from the declared type of the binding (`val n: int =
o.get("n")`); when neither exists the getter is `orbit_object_get_raw`, which
returns a `const char*`, and the destination keeps the type the builder wrote
(`unknown` or `object`). The emitter applies this typing before it writes the
document (`typeObjectFieldReads`), so the document carries the type and no
consumer repeats the scan. The builder's `fieldKind` is not a document field.

Audit notes:

- The observed `free` no-op and `type_info` comment are NOT semantics:
  they stay `UNSPECIFIED` (U-09, U-12).
- The union layout `{int tag; void* data;}` is locally emitted text, not a
  contractual runtime helper: it stays `UNSPECIFIED` (U-14).
- `ORBIT_API_RESPONSE` is not declared in `runtime/orbit_api.h` (search with
  zero results): its definition point stays `UNSPECIFIED` (U-15).
- The `orbit_db_*` symbols do not exist in the net variant (§4, DB drift).

## 2. Value and structure model

### 2.1 `IRValue` (tagged union, `ir.orb:80-89`)

| Variant | Payload | Constructors (`ir.orb:108-140`) |
|---|---|---|
| `Int` | `int`, signed | `ir_int` |
| `Float` | `float` (== `double` in C, §4) | no dedicated constructor observed |
| `String` | `string` (literal) | `ir_string` |
| `Sym` | `string` (name/symbol) | `ir_symbol` |
| `Bool` | `bool` | `ir_bool` |
| `Register` | `int` (register number) | `ir_register` |
| `Label` | `int` (label number) | `ir_label` |
| `None` | — | `ir_none` |

Observed C rendering (`generateValue`, `c_backend.orb:2363-2381`): `Int` →
decimal; `Float` → `orbit_float_to_string_selfhost`; `String` → quoted
with `escapeString`; `Sym` → raw; `Bool` → `true`/`false`; `Register(n)` →
`r_N` (`n<0` → `"0"`); `Label(n)` → decimal; anything else → empty string.

### 2.2 `IRInstruction` (`ir.orb:91-105`)

- `opcode`: one of the 66 (§1).
- `dest`: `int`. `-1` means no destination. Default factory value `-1`
  (`ir_init_instr`, `ir.orb:142-144`).
- `operand1/2/3`: `IRValue`. Unused ones are `None`.
- `elemKind`: `int` holding the list element-type code
  (`builder.orb:1356-1363`): `0` undecided, `1` string, `2` int, `3` float,
  `4` bool, `5` ref. Only the collection opcodes set it. Only the builder
  decides it (`ir.orb:97-104`). `0` lowers to the untyped accessor and to a
  `void*` destination. Which exact spellings yield `5`
  (`isReferenceKindName`) is not audited here:
  `UNSPECIFIED` (U-01).
- Destination register type: `registerTypeForElemKind` (`builder.orb:1380-1386`):
  `1→"string"`, `2→"int"`, `3→"float"`, `4→"bool"`, anything else → `"unknown"`.

### 2.3 `IRFunction` (`ir.orb:146-161`)

Fields in order: `name`, `params` (names), `paramTypes` (same length),
`instructions`, `registerCount`, `registerTypes` (length == `registerCount`),
`returnType`, `isExtern`, `routeMethod`, `routePath`, `routeHasLimit`,
`routeLimitRate`, `routeLimitWindowMs`, `routeLimitBurst`.

- `ir_alloc_register` (`ir.orb:171-176`): the number is the current counter, and
  it appends the typeName to `registerTypes`. Observed type vocabulary (open, not
  restricted): `"int"`, `"bool"`, `"string"`, `"float"`, `"unknown"`, `"void"`,
  `"void*"`, `"result"`/`"Result"`/`"OrbitResult"`, `"response"`, `"map"`,
  `"list"`, `"object"`, `"string_list"`/`"int_list"`/`"float_list"`/`"bool_list"`/`"ref_list"`,
  spellings `list<…>` / `map<…>`, spellings `fn(params)->ret`, `orbit_*` aliases,
  model and enum types. The loader must accept any string.
- Typed destinations: the builder writes the type of the destination when the
  front end proves it, and `"unknown"` otherwise. `eq`, `ne`, `lt`, `le`, `gt`
  and `ge` always have `"bool"`. A `load_var` of a local declared from a
  literal, an operator expression or an interpolation has that expression's
  static type (`int`, `float`, `bool` or `string`). `add`, `sub`, `mul` and
  `div` have the operands' type when both are `int` or both `float` (`add`
  also when either is `string`); `mod` and the bitwise operators when both are
  `int`; `neg` the operand's type when it is `int` or `float`; `bit_not` `int`
  when the operand is `int`. `load_field` of a model field whose receiver type
  is resolved and whose declared type is `int`, `float`, `bool` or `string`
  has that type, and so does a field declared `list` or `list<T>` (`list`), as
  a declared enumeration, as a declared non-generic model or as a declared
  union; a generic instance or a type-parameter field stays `unknown`. A `call` by name
  to a model that is not generic has that model's name, and a call to the
  builtin `print` has `void`. A `load_var` of `Enum_TAG_Variant` written as
  `Enum.Variant`, where `Enum` is an enumeration, has the enumeration's name.
  A `result_unwrap` bound by `val x: T = try ...` has the register type of the
  annotation when it is `int`, `float`, `bool`, `string` or `list`, and the
  emitter casts the word to it. An unwrap without such an annotation stays
  `unknown`. A `list_get` or `list_pop` bound by `val x: T = ...` with an element type the
  list did not record has the annotation's register type when it is `int`,
  `bool`, `string`, `list`, a declared non-generic model or a declared union
  (float stays `unknown`). A `list_get` of a reference element has `list` when the list's
  element is a list and the declared name when it is a non-generic model or
  a union; an enumeration, a type parameter or an unrecorded element stays
  `unknown`, and the local it is bound to takes the same type. A `load_field`
  of `length` or `len` on a `string` receiver has `int`, and so does a `call`
  to `orbit_string_len` or `orbit_string_indexOf`. A `union_get_data` for a variant with one `int`, `bool` or
  `string` payload has that type, and the emitter casts the word to it. A
  variant with one payload that is a declared non-generic model or a union has
  that name, and the word is the pointer; a float
  payload and the packed-struct pointer of a multi-payload variant stay
  `unknown`. No new spelling enters the vocabulary above.
- The document never contains `"unknown"`. The builder's `unknown` is written
  as `"void*"` in `registerTypes`, `paramTypes` and `returnType`
  (`irTypeName`), because that is what `mapTypeToC` declares for it: one
  pointer word. Before the write, `--emit-ir` retypes an object field read by
  its getter (§1.4) and a register compared with a constant by the constant's
  type, the two steps the C backend takes when it declares registers. On the
  corpus, every `void*` register is declared `void*` in the C of the same
  program (compiled with `ORBIT_NO_CTE=1`, which keeps the register numbers).
  A register typed `void*` is a value the compiler cannot type: an unwrapped
  result without an annotation, a union payload word, a list element of a
  generic or reference kind the builder did not name, a call to a generic
  function instantiated with no type.
- `registerTypes` is advisory and is rewritten during emission
  (`inferRegisterTypes`, `c_backend.orb:575-1095`): the loader must not assume
  the final C (or the native binary) derives from them alone.
- `isExtern == true` → the backend emits neither prototype nor definition
  (`c_backend.orb:193,248`): the symbol resolves outside. Resolution is
  `UNSPECIFIED` (U-16).
- `routeMethod == ""` ⇔ plain function. `initRouteFunction` pins the return
  type to `"OrbitResponse*"` (`ir.orb:167-169`). Optional Kynx route limits
  (`c_backend.orb:78-90,1837`).
- Parameters additionally live in a flat name-keyed kind registry
  (`listKinds`) restored per scope (`listKindMarks`). Two functions sharing a
  parameter name share one entry (`builder.orb:44-74,110-123,
  AGENTS.md`). Not reproducible in serialized IR: `UNSPECIFIED` (U-02).

### 2.4 `IRModule`, models, types, globals, migrations

- `IRModule` (`ir.orb:220-226`): `functions`, `globals`, `models`, `types`,
  `migrations` (all lists).
- `IRGlobal` (`ir.orb:228-232`): `name`, `value` (`IRValue`), `typeName`.
  Observed constructors: `ir_string` value (`builder.orb:2336,2372`) or
  `ir_register` value (`builder.orb:2377`). Top-level `var`/`const` is error
  E1007. `val NAME = <int|bool lit>` is a global `#define` emitted by
  `generateRoutePreamble`, not by `route_runtime` (AGENTS.md).
- `IRModelDecl` (`ir.orb:187-198`): `name`, `fields` (`IRModelField{name,
  typeName}`), `typeParams`. A declaration with non-empty `typeParams` NEVER
  reaches the module: it lives in `builder.genericModels`. Only synthesized
  instances (`Box_int`, fields already substituted) enter `module.models`
  with `typeParams == []` (`builder.orb:647,682,2026-2034`).
- `IRTypeDecl` (`ir.orb:212-218`): `name`, `kind`, `variants` (strings),
  `richVariants` (strings), `methods` (strings). Observed
  (`builder.orb:2044-2072`): `"enum"→"enumeration"`, `"union"→"union_type"`,
  any other `kind` passes through unchanged (`"alias"`, `"trait"` unrenamed);
  `variants` = literal texts; `richVariants` = payload spellings;
  **`methods` is always `[]`** (literal at `builder.orb:2070`).
- `IRVariantDecl`/`IRVariantField` (`ir.orb:200-210`): declared but with no
  constructor site in `builder.orb` (only type mentions at
  `builder.orb:1312`). Population is `UNSPECIFIED` (U-03).
- `migrations`: list of SQL strings (`builder.orb:2037-2039`, emitted at
  `c_backend.orb:1816-1825`). With migrations or DB use, the preamble
  initializes `orbit_db_init(".orbit/data/app.db")` and closes with
  `orbit_db_close()` (`route_runtime.orb:484,666`).

## 3. Calling convention

### 3.1 `arg` / `call` protocol

1. Each `arg` without `dest` appends `generateValue(O1)` to the backend's
   pending stack (`callArgs`) (`c_backend.orb:2676`).
2. `call` reads O1: `String`/`Sym` → named call; any other value →
   indirect call.
3. O2 (`Int`) is the arity recorded by the builder: the `call` consumes
   exactly the last `numArgs` pending values (`2828-2829`). Zero arity
   means zero (no fallback to "all pending", `2824-2828`).
4. Aliases applied by the backend (`2759-2767`): `slice→orbit_string_slice`,
   `at→orbit_string_at`, `find`/`indexOf`/`orbit_string_find→orbit_string_indexOf`.
5. Arity minimums enforced by the backend (`2811-2823`): `orbit_string_at`,
   `orbit_string_indexOf`, `strcmp` → 2; `orbit_string_slice` → 3;
   `orbit_string_concat` → 2.
6. `print` with exactly 1 pending value: string → `print("%s",…)`; float
   register → `printf` with `orbit_float_to_string`; anything else →
   `printf("%lld\n", (long long)(…))` (`2772-2794`). With !=1 args it emits
   `/* print */` and drops the pending values (`2795-2800`). Observed
   behavior, not a formatting contract (U-17).
7. No `dest` needed when the callee returns void or is `orbit_list_set`
   (`2768-2771`).
8. Names that are C keywords get a trailing `_` at the call site
   (`isCKeyword`, `2884-2891`). The definition uses `sanitizeIdentifier`
   with the same rule.
9. Some calls receive `arena` as the first argument (`functionNeedsArena`,
   `2893`): the exact list is not audited here → `UNSPECIFIED` (U-04).
10. Indirect call (`2693-2757`): O1 is the function value (register); the
    `fn(params)->ret` signature comes from the register type; per-argument
    casts are `orbit_int`/`orbit_string`/`orbit_float`/raw/`void*` according
    to the parameter type; a `"void"` return suppresses the destination.
    Argument evaluation order is `UNSPECIFIED` (U-05).

11. Argument conversion. The IR has no conversion opcode. A named call to a
    function of the module converts each argument to the callee's `paramTypes`
    entry at the call site, as a C value conversion and not a reinterpretation
    of bits. An `int` passed to a `float` parameter is converted: the
    backend writes `takesFloat(arena, (orbit_float)(2))`
    (`tests/suite/call_arg_types.orb`). A float literal is a `Sym` operand
    holding its source text (`2.5`), typed `float` by its register.

### 3.2 Functions, registers, return

- Every non-extern function is declared (prototype) and defined. Non-`main`/
  non-route → `static`. `main` (or its alias) → `orbit_main`, returning
  `int`. Route → returns `OrbitResponse*` with signature
  `(OrbitArena* arena, OrbitRequest* req)` (`c_backend.orb:193-236`).
- C types via `mapTypeToC` (`c_backend.orb:359-…`): `int→orbit_int`,
  `float→orbit_float`, `string→orbit_string`, `bool→orbit_bool`,
  `void→void`, `list*→OrbitList*`, `map*→OrbitMap*`, `object→OrbitObject*`,
  `result→OrbitResult`, `response→OrbitResponse*`, enums → their own name,
  `list<…>`/`map<…>` by base, trailing `*` preserved. Rest: pointer
  fallback (exact tail rule of the function not audited → U-06).
- Physical registers `r_N`. The declaration type comes from
  `registerTypes[N]. `ret` emits by `returnType` (§1.2, `3192-3273`).
- `orbit_print` is declared `void orbit_print(const char* str)`
  (`runtime/orbit_api.h:611`).

### 3.3 Runtime symbols the builder calls

The builder lowers some source forms to a `call` of a runtime symbol the
program never declared: string methods (`len`, `at`, `slice`, `find`), object literals,
`Model.all()` and `Model.where(...)`, and `system.uptime()`. `emitIRv1` adds
one `isExtern: true` function entry for each such symbol the module calls
(`ir_emit.orb`, `irRuntimeExterns`), after the module's own functions and in
order of first call. The entry has `instructions: []`, `registerCount: 0` and
no route fields. The module the C backend reads is not changed, so the C
bytes are the same.

`params` and `paramTypes` list the arguments of the IR `call`. The leading
`OrbitArena* arena` of a symbol in `functionNeedsArena` (§3.1 item 9) is not a
parameter: the C backend prepends it at the call site.

| Symbol | Parameters | Returns | Header |
|---|---|---|---|
| `orbit_string_len` | `s: string` | `int` | `orbit_api.h:427` |
| `orbit_string_at` | `s: string, index: int` | `int` | `orbit_api.h:401` |
| `orbit_string_slice` | `s: string, start: int, end: int` | `string` | `orbit_api.h:402` |
| `orbit_string_slice_known_len` | `s: string, start: int, end: int, totalLen: int` | `string` | `orbit_api.h:403` |
| `orbit_string_indexOf`, `orbit_string_find` | `s: string, substr: string` | `int` | `orbit_api.h:413` |
| `orbit_object_create` | none | `object` | `orbit_api.h:578` |
| `orbit_object_set_int` / `_float` / `_bool` / `_string` / `_object` / `_list` | `o: object, key: string, v: T` | `void` | `orbit_api.h:580-585` |
| `orbit_db_query_all`, `orbit_db_query_first` | `table: string` | `string` | `database.c` |
| `orbit_db_query_where` | `table: string, condition: string` | `string` | `database.c` |
| `orbit_db_query_where_p` | `table: string, condition: string, param: string` | `string` | `database.c` |
| `orbit_db_query_get` | `table: string, id: string` | `string` | `database.c` |
| `orbit_db_query_order`, `orbit_db_query_order_desc` | `table: string, column: string` | `string` | `database.c` |
| `orbit_db_count_all` | `table: string` | `int` | `database.c` |
| `orbit_db_insert` | `table: string, json: string` | `bool` | `database.c` |
| `orbit_db_update` | `table: string, id: string, json: string` | `bool` | `database.c` |
| `orbit_db_delete` | `table: string, id: string` | `bool` | `database.c` |
| `system_uptime`, `system_pid`, `system_active_workers`, `system_http_requests_total`, `system_latency_avg_us`, `system_latency_p50_us`, `system_latency_p95_us`, `system_latency_p99_us` | none | `int` | `orbit_api.h:646-653` |

`T` in `orbit_object_set_*` is `int`, `float`, `bool`, `string`, `object` or
`list`. `orbit_string_find` is the source-level alias of `orbit_string_indexOf`
(§3.1 item 4): the entry keeps the name the `call` uses. The `orbit_db_*` rows
follow `runtime/database.c`, because the net header declares none of them (§4).
The variadic `orbit_db_query_where_v` and `orbit_db_count_v` have no entry:
their argument count rides in the call, and an extern cannot state it.

Three kinds of call target stay undeclared on purpose. `print` is a language
builtin with the lowering of §3.1 item 6, unless the program writes its own
`extern fn print`. A model constructor (`Point(...)`) is declared by the
`models` list. A union variant constructor (`Circle(...)`) is declared by the
`types` list.

## 4. Runtime and DB drift (contractual)

- `runtime/orbit_api.h` is the separate-compilation header against
  `.orbit/lib/libruntime_net.a` (**net variant, no DB**, `orbit_api.h:3-13,106`):
  ```c
  typedef const char* orbit_string;   /* h:113 */
  typedef int         orbit_int;      /* h:114 — 32 bits on both x86-64 targets */
  typedef double      orbit_float;    /* h:115 */
  ```
  `OrbitResult` (`h:177-184`), `OrbitList` (`h:212-224`), `OrbitMap`
  (`h:231-239`), `OrbitRequest`/`OrbitResponse` (`h:280-290`), helpers
  `orbit_list_*_typed/push_*/read_*` (`h:361-531`), `orbit_map_*` (`h:378-382,
  534-554`), `orbit_result_ok/float/err` (`h:321-325`), `orbit_alloc`
  (`h:334`), `orbit_response_*` (`h:697-703`).
- **DB drift:** the backend emits `orbit_db_get/set/all/where`
  (`c_backend.orb:3533-3591`) plus the `orbit_db_init/close` preamble, but the
  net library neither declares nor links any `orbit_db_*` symbol (zero hits
  in `orbit_api.h`). Until a published, pinned DB runtime artifact exists,
  the `db_get/db_set/db_all/db_where` opcodes are excluded from the M1
  differential. No shims, no silent omission: the loader rejects them.

## 5. IRv1 textual format

### 5.1 Format decision

IRv1 text is a **UTF-8 JSON document** (RFC 8259): a single root object, no
BOM, trailing LF. JSON is the format. There is no assembly-like text
representation and no binary encoding at this pin (no `--emit-ir` exists, so
this section defines the text form from the in-memory model in §2).

- Root object fields, in order: `irVersion` (must be the string `"1"`),
  `module` (an `IRModule` object, §2.4).
- Key names mirror the model field names exactly: `functions`, `globals`,
  `models`, `types`, `migrations`; function keys `name`, `params`,
  `paramTypes`, `instructions`, `registerCount`, `registerTypes`,
  `returnType`, `isExtern`, `routeMethod`, `routePath`, `routeHasLimit`,
  `routeLimitRate`, `routeLimitWindowMs`, `routeLimitBurst`; instruction keys
  `opcode`, `dest`, `operand1`, `operand2`, `operand3`, `elemKind`.
- Integers are JSON numbers without fraction or exponent, within the signed
  32-bit range except register/label numbers, which are non-negative, and
  `dest`, which is `-1` or non-negative (§5.4, rules V-06/V-07).
- Floats are JSON numbers. Non-finite values are rejected (V-08). The
  rendering of a float back to C is `orbit_float_to_string_selfhost`
  (§2.1), not JSON formatting.
- Strings are JSON strings. The C-side escaping table is `escapeString`
  (`c_backend.orb:2338-2361`). Its exact byte coverage stays `UNSPECIFIED`
  (U-07).
- Booleans are JSON `true`/`false`. Unused operands are the value object
  `{"kind":"None"}` (§5.2).
- Field order in the emitted document follows the model declaration order
  (§2.3/§2.4). The loader must accept any order but must reject unknown
  keys (V-02).
- A document containing an authoring-tool elision marker (the
  `…[N chars]` text left by a cut-off write) must fail validation (V-01).

### 5.2 JSON text grammar (EBNF) + minimal runnable example

EBNF over JSON values (`(* … *)` are comments, and terminals are JSON literals):

```ebnf
document    = object, "irVersion", ":1", "module";
module      = "{", functions, globals, models, types, migrations, "}";
functions   = "[", { function }, "]";
function    = "{", name, params, paramTypes, instructions, registerCount,
              registerTypes, returnType, isExtern, routeMethod, routePath,
              routeHasLimit, routeLimitRate, routeLimitWindowMs,
              routeLimitBurst, "}";
instructions = "[", { instruction }, "]";
instruction = "{", opcode, dest, operand1, operand2, operand3, elemKind, "}";
opcode      = '"', opname, '"';      (* one of the 66 names in §1 *)
dest        = "-1" | uint;
operand1    = value;                 (* operand2, operand3: same *)
value       = none | intVal | floatVal | strVal | symVal | boolVal | regVal
              | labelVal;
none        = '{"kind":"None"}';
intVal      = '{"kind":"Int","value":', sint, '}';
floatVal    = '{"kind":"Float","value":', number, '}';
strVal      = '{"kind":"String","value":', jsonString, '}';
symVal      = '{"kind":"Sym","value":', jsonString, '}';
boolVal     = '{"kind":"Bool","value":', ("true" | "false"), '}';
regVal      = '{"kind":"Register","value":', uint, '}';
labelVal    = '{"kind":"Label","value":', uint, '}';
elemKind    = "0" | "1" | "2" | "3" | "4" | "5";
globals     = "[", { global }, "]";
global      = "{", name, value, typeName, "}";
models      = "[", { modelDecl }, "]";
modelDecl   = "{", name, fields, typeParams, "}";
types       = "[", { typeDecl }, "]";
typeDecl    = "{", name, kind, variants, richVariants, methods, "}";
migrations  = "[", { jsonString }, "]";
```

Minimal runnable example — `fn main() -> int { return 0 }`, i.e. one
`load_const` plus `ret` (`c_backend.orb:2427-2430,3192-3273`):

```json
{"irVersion":"1","module":{
  "functions":[{
    "name":"main","params":[],"paramTypes":[],
    "instructions":[
      {"opcode":"load_const","dest":0,
       "operand1":{"kind":"Int","value":0},
       "operand2":{"kind":"None"},"operand3":{"kind":"None"},"elemKind":0},
      {"opcode":"ret","dest":-1,
       "operand1":{"kind":"Register","value":0},
       "operand2":{"kind":"None"},"operand3":{"kind":"None"},"elemKind":0}
    ],
    "registerCount":1,"registerTypes":["int"],"returnType":"int",
    "isExtern":false,"routeMethod":"","routePath":"",
    "routeHasLimit":false,"routeLimitRate":0,
    "routeLimitWindowMs":0,"routeLimitBurst":0}],
  "globals":[],"models":[],"types":[],"migrations":[]}}
```

Expected lowering: `orbit_main` returning `int` (`§3.2`), body
`r_0 = 0; return r_0;` (register declaration type from `registerTypes[0]`).

### 5.3 Edge cases (12)

| # | Case | Expected loader behavior | Grounding |
|---|---|---|---|
| E-01 | `dest: -1` on `load_const` | Reject (V-10); value-producing opcodes require a destination | `ir_init_instr` default `-1`, §2.2 |
| E-02 | `Register(-1)` operand value | Reject (V-09); negative register ids are not encodable | `generateValue` maps `n<0` to `"0"` |
| E-03 | `elemKind: 5` on `list_get` with `registerTypes[D] == "void*"` | Accept; ref elements the builder cannot name stay `"void*"` | `builder.orb:1368-1378` |
| E-04 | `elemKind: 0` on `list_create` | Accept; untyped accessor + `void*` destination | `ir.orb:97-104` |
| E-05 | `call` with O2 arity `0` and pending `arg` nodes present | Consume zero args (no "all pending" fallback) | `c_backend.orb:2824-2828` |
| E-06 | `print` call with 2 pending args | Accept the IR; lowering emits `/* print */` and drops them | `c_backend.orb:2795-2800` |
| E-07 | `label` never targeted by a jump | Accept; lowering omits the label (`label_N:;` only when referenced) | `c_backend.orb:2642-2647`, `refLabels` |
| E-08 | `jump` to an undeclared label number | Reject (V-14) | `refLabels` collection `2085-2089` |
| E-09 | `isExtern: true` function with a non-empty `instructions` list | Accept but ignore the body (no prototype/definition emitted) | `c_backend.orb:193,248` |
| E-10 | `routeMethod: ""` with non-empty `routePath` (and vice versa) | Reject (V-16); plain vs route is decided by `routeMethod` alone | `ir.orb:167-169`, §2.3 |
| E-11 | `IRTypeDecl.methods` non-empty | Reject (V-17); the builder always writes `[]` | `builder.orb:2070` |
| E-12 | `db_get`/`db_set`/`db_all`/`db_where` opcode present | Reject (V-19, DB exclusion); no shim, no silent skip | §4, M1 differential |

### 5.4 Validation rules (19, numbered V-01–V-19)

A loader must apply these in order. The first failure wins, and its diagnostic
names the opcode/field (gap rule, header). "Reject" = fatal loader error.

| # | Rule |
|---|---|
| V-01 | The document is UTF-8 JSON (RFC 8259), a single root object, no BOM, trailing LF; it contains no elision marker. |
| V-02 | The root object has exactly `irVersion` (`"1"`) and `module`; unknown keys are rejected. |
| V-03 | `opcode` is one of the 66 names in §1, spelled exactly (no aliases, no case folding). |
| V-04 | `elemKind` is an integer in `0..5`; non-collection opcodes must carry `0`. |
| V-05 | Every operand is a `{"kind":…}` object with one of the 8 kinds in §2.1 and a correctly typed `value` (absent only for `None`). |
| V-06 | Integer values have no fraction/exponent and fit in signed 32 bits. |
| V-07 | `dest` is `-1` or a non-negative integer; `Register`/`Label` values are non-negative integers. |
| V-08 | Float values are finite JSON numbers (no NaN/Infinity). |
| V-09 | No negative register id is encodable (E-02). |
| V-10 | Value-producing opcodes (`load_const`, `load_var`, `copy`, `call` with non-void return, all of §1.2 with `D ← …`) have `dest >= 0`; `arg` without `dest` keeps `dest == -1`. |
| V-11 | `registerCount` equals the length of `registerTypes`; every `dest`/`Register(n)` satisfies `n < registerCount`. |
| V-12 | `params` and `paramTypes` have equal length; every `arg`-with-`dest` index is within range. |
| V-13 | `call` O2 arity is a non-negative `Int` and does not exceed the pending `arg` count at that point (E-05). |
| V-14 | Every `jump`/`jump_if_false` target has a matching `label` number in the same function (E-08). |
| V-15 | `IRModelDecl` entries have `typeParams == []` (generic declarations never reach the module, §2.4). |
| V-16 | `routeMethod == ""` implies `routePath == ""` and all route-limit fields zero/false (E-10). |
| V-17 | `IRTypeDecl.methods` is `[]` (E-11). |
| V-18 | `isExtern == true` functions resolve their symbol outside; their body, if present, is ignored, never emitted (E-09, U-16). |
| V-19 | `db_get`/`db_set`/`db_all`/`db_where` are rejected under the DB exclusion (E-12, §4). |

### 5.5 Designated corpus

At this pin the corpus is the language test tree itself (no serialized IR
exists yet). Each source below maps to IR through the builder whose producers
are pinned in §1.1.

- **Suite: 114 runnable files + 1 support file.** `tests/suite/` holds 115
  `.orb` files: 114 runnable programs plus `imports.support.orb` (imported by
  `imports.orb`, never compiled alone). The `.skip` file (`fn_call.orb.skip`)
  is not a corpus member.
- **Standard library: 23 files.** `tests/std/` holds 23 `.orb` programs
  (`test_assert`, `test_bitwise`, `test_bytes`, `test_codec`, `test_collections`,
  `test_collections_boxed`, `test_convert`, `test_crypto`, `test_fs`,
  `test_hash`, `test_http_client`, `test_imports`, `test_io`, `test_json`,
  `test_log`, `test_process`, `test_process_exit`, `test_random`,
  `test_regex`, `test_string`, `test_time`, `test_time_ns`, `color_smoke`),
  covering the 19 shipped `std/**/*.orb` modules (the 1 `std/quarantine/*.orb.quarantined`
  file is excluded).
- **DB exclusions, counted: 4 opcodes + 0 corpus files removed, 1 file flagged.**
  The 4 `db_*` opcodes (`db_get`, `db_set`, `db_all`, `db_where`) are excluded
  from the M1 differential (§4): they have no producer in `compiler/**/*.orb`
  and no symbol in the net runtime. No corpus file is removed: the single
  suite file touching DB access, `peephole_no_fold_side_effects.orb`
  (via `Item.all()`/`Item.where()`, which lower through `call` to
  `orbit_db_query_*`, `builder.orb:295-306`), stays as `call`-opcode coverage.
  No `tests/std/*.orb` file uses DB access.

## 6. Gaps (17, U-01–U-17)

Every item below is `UNSPECIFIED`: the loader rejects any document that
depends on it, with a diagnostic naming the opcode/field (gap rule, header).
Numbers U-01–U-06, U-09, U-12, U-14–U-17 are kept as cited in §§1–4. U-07,
U-08, U-10, U-11, U-13 complete the sequence.

| # | Gap | Why it is open at this pin |
|---|---|---|
| U-01 | Which type spellings yield `elemKind` 5 (`isReferenceKindName`) | Predicate not audited here (§2.2). |
| U-02 | The flat name-keyed `listKinds` registry shared across functions | Not reproducible in serialized IR (§2.3). |
| U-03 | Population of `IRVariantDecl`/`IRVariantField` | Declared, no constructor site in the builder (§2.4). |
| U-04 | Exact `functionNeedsArena` list (which calls get a prepended `arena`) | Not audited here (§3.1, `c_backend.orb:2893,4211-4236`). |
| U-05 | Argument evaluation order of the indirect `call` | Unfixed by the observed lowering (§3.1). |
| U-06 | Exact pointer-fallback tail of `mapTypeToC` | Tail rule not audited here (§3.2, `c_backend.orb:359-…`). |
| U-07 | Exact byte coverage of `escapeString` (e.g. non-ASCII, control bytes other than `\"`, `\n`, `\r`, `\t`, `\x1b`) | Table at `c_backend.orb:2338-2361` not pinned byte by byte (§5.1). |
| U-08 | Exact C keyword set of `isCKeyword`/`sanitizeIdentifier` | List at `c_backend.orb:1258-1310` quoted but not versioned as a contract (§3.1). |
| U-09 | `free` semantics | Observed as a no-op comment; not semantics (§1.2). |
| U-10 | Exact rewrite rules of `inferRegisterTypes` (3 passes, `c_backend.orb:562-1095`) | Advisory `registerTypes` may change under emission; the pass rules are not pinned here (§2.3). |
| U-11 | Exact cast rules of `storeCastFor` / `load_var` casts | Cast selection observed but its table is not pinned here (§1.2). |
| U-12 | `type_info` semantics | Observed as a comment only (§1.2). |
| U-13 | Label liveness beyond `refLabels` (duplicate labels, `label` after `ret`, cross-block jumps) | Only the referenced-emits rule is observed (`c_backend.orb:2077-2089,2642-2647`). |
| U-14 | Union `{int tag; void* data;}` layout | Locally emitted text, no contractual runtime helper (§1.2). |
| U-15 | Definition point of `ORBIT_API_RESPONSE` | Not declared in `runtime/orbit_api.h` (§1.2). |
| U-16 | Resolution of `isExtern` symbols | Backend emits nothing; resolution is outside (§2.3). |
| U-17 | `print` formatting contract | Observed behavior only; the multi-arg case is a comment (§3.1). |