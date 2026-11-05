# Changelog

Every entry below comes from the git history - condensed to
one line per change, grouped by what it was for. Nothing here
is reconstructed from memory. (`git log --oneline` tells the
full story; this page tells the short one.)

Versioning rules: [Versioning and Compatibility](VERSIONING.md).
Current: `0.1.0` (`orbit --version` prints `orbit 0.1.0`, and the
startup banner says `Orbit 0.1.0`).

## 0.1.0 (2026-11-01)

Language front end:

- **A `try` binding annotation is checked against the payload.** The checker answered `unknown` for a `try` expression, and the compatibility rules accept `unknown` for anything, so `val n: int = try decode("x") catch { ... }` over a `-> result<string>` built and ran with an int register holding a string pointer. The arm now answers the payload the callee's signature writes -- `compatTypeResultPayload` (`compiler/front/sema.orb:1845`) already read it for the compatibility rule -- so the annotation is compared with what the read yields. A bare `-> result` writes no payload and still answers `unknown`, which is the half this limitation keeps. `tests/negative/n123_try_annotation_payload.orb` pins the refusal, so the corpus is 116 cases. The suite is 127/127, `tests/std` 24/24 and the parity probes 33/33 with their goldens: no program in the tree had been relying on the unchecked annotation. The census is untouched, which measures the frontend pass and not the checker: 393 unknown over 104,185 instructions.

- **A labelled `break` finds its loop.** `for outer: k in 0..n { break outer }` refused the whole loop because the two targets the pass carried were the innermost loop's. The function now keeps the stack the build keeps -- a name and the two blocks a labelled `break` and `continue` jump to (`compiler/ir/builder.orb:20`, searched innermost-first at `compiler/ir/builder.orb:3467`) -- so the label resolves to its own loop's exit and an unknown label says that instead of refusing the loop. Over the corpus the row that printed 4 prints nothing, and 3 of those loops moved to the element-kind question, which is the answer their receivers still do not write. E3001 falls 364 to 363 and the census reads 393 unknown over 104,185 instructions -- 0.4%, ratchet 4 per mille, silent 0, and the five per-code counts still sum to the total. `tests/frontend/labelled_break.orb` and its golden were written before the rule and matched on the first run, all 29 instructions. The frontend gate is 49/49.

- **A named `catch` reads its message.** `try pick(c) catch e { return 9 }` was a give-up that said `a catch with a name needs the error type`, while the build opens that handler with a read of the message: `result_unwrap_err` into a register typed `string` (`compiler/ir/builder.orb:5920`), which is what `compiler/emit/c_backend.orb:870` says the read is. The pass emits the same two instructions before the handler body, and one helper opens the handler for both `try` shapes, so the value case and the statement case cannot drift. Over the corpus the census reads 393 unknown over 104,120 instructions -- 0.4%, ratchet 4 per mille, silent 0. E2001 loads fall 180 to 175 and E2002 binary operands 53 to 52, and E3001 falls 370 to 364: the named-catch row printed 6 and prints nothing, leaving 6 fall-through handlers as the only `try` question this pass does not answer. `tests/frontend/try_named_catch.orb` and its golden were written before the rule; the first version did not even parse, because `use` is a keyword, and after the rename the text matched on the first run. The frontend gate is 48/48.

- **A `try` binding annotation answers the read.** `val n: int = try digit(c) catch { return 9 }` over a function declared `-> result` asked for a value type the signature does not write. The build retypes that read to the annotation -- `compiler/ir/builder.orb:3140` lists exactly `int`, `bool`, `string`, `float` and a `list` base -- and the checker has already compared the annotation with the value, so the pass reads the same promise. The signature still wins when it writes a payload. Over the corpus the census reads 399 unknown over 103,986 instructions -- 0.4%, ratchet 4 per mille, silent 0. E2001 loads fall 205 to 180 and E3001 give-ups 392 to 370: the value-type class prints no row now, while 6 fall-through handlers and 6 handlers that name their error remain, both answered by
questions behind the annotation. `tests/frontend/try_binding_annotation.orb` and its golden were written before the rule and matched on the first run, register numbering included. The frontend gate is 47/47.

- **A `for` over a list that says what is inside iterates.** The loop was a give-up for every receiver. `buildForList` (`compiler/ir/builder.orb:3530`) had already decided its blocks: the hidden `<item>_idx` counter, one length read before the loop, and the item through `list_get`. The pass emits that, and the item's type is `listElementKind` of the receiver's type text -- the same source `get`, `at`, `pop` and the index form answer from. A bare `list` still writes nothing about its inside and stays a give-up. Over the corpus 12 of the 20 list loops lowered and E3001 fell 404 to 392. The unknown count is one higher, 425 over 103,614 instructions: a loop body that was never read now contributes 321 instructions, and one `+` in them has an operand no table answers. Per mille the ratchet metric holds at 4 and the silent count is 0. `tests/frontend/list_iteration_typed.orb` and its golden were written before the rule and matched on the first run, numbering included. The frontend gate is 46/46.

- **The payload table reads `object`.** `val o: object = try parse(t) catch { ... }` asked for the value type the signature already wrote, because `declaredPayloadType` (`compiler/tir/lower.orb:249`) answered four builtin words and nothing else. `object` is the fifth, the same string this pass prints for an object literal and for a field read of one. Over the corpus the census reads 424 unknown of 103,336 instructions -- 0.4%, ratchet 4 per mille, silent 0. E2001 loads fall 230 to 205: the values those `try` bind load back typed. Six more `try` give-ups left and the class reads 34, every one of them a callee declared `-> result` with nothing inside -- a signature that writes no payload is not a type this pass invents. `tests/frontend/try_object_payload.orb` and its golden were written before the rule and matched on the first run. The frontend gate is 45/45.

- **A `try` used as a statement lowers.** `try decode("x") catch { refused = true }` reached the expression reader, which asks what type the value has and then what merges when the handler falls through. In statement position nothing reads the value, so neither question belongs. The pass emits `result_is_ok` and the `branch`, and both arms jump to the block the statements after the `try` are lowered into -- the two-arm block the `if` statement already emits. Over the corpus `E3001` falls 448 to 410: the handler class prints no row (its 20 were all statement uses) and 19 more of the value-type class left with them. The `unknown` count did not move, 449 of 103,281 instructions -- 0.4%, ratchet 4 per mille, silent 0 -- because a give-up types no instruction, while 178 instructions entered the corpus where the give-ups used to stop the lowering. `tests/frontend/try_statement_handler.orb` and its golden were written before the rule and matched on the first run, numbering included. A `try` in expression position still asks both questions: 40 want the payload written, 1 wants a named `catch` typed.

- **A `result` that names a numeric payload accepts `ok` with that number.** `-> result < int >` parsed, and the checker answered `ok response body must be a string or an object, got int`. The guard compared the declared return with the word `result` exactly, so a signature that wrote its payload fell into the HTTP-response rule. It compares the base type now, the way the compatibility check beside it does. `compiler/emit/c_backend.orb:4341` already stores a number through `(void*)(uintptr_t)` and `:4383` reads an `int` destination back, so nothing downstream changed. `std/string/string.orb:196` and `:233` write `result < int >` and `result < float >`, and `std/json/json.orb:49` writes `result < object >`. Over the corpus the census reads 449 unknown over 103,103 instructions -- 0.4%, and the ratchet metric holds at 4 per mille. The `try` give-ups fell 85 to 79: 15 stopped asking for a value type and 9 of them became the handler class behind them. 17 stay, and they are `result < object >` -- `declaredPayloadType` (`compiler/tir/lower.orb:249`) answers the four builtin payloads and nothing else. `tests/suite/result_payload_int.orb` is the program; it failed with the refusal above before the change and exits 0 now.

- **An index read is the call the build already emits.** `xs[i]` was a give-up where `xs.get(i)` was an instruction, although `compiler/ir/builder.orb:5820` lowers both spellings to `IROpcode.list_get`. The index form now travels as `call <kind> get <container> <index>`, with the element kind read from the receiver's type text. The count did not move: the 8 index reads in the corpus sit under a `list` whose type text names no element kind, so they changed message, not type. The census reads 454 unknown over 102,961 instructions -- 0.4%, and the ratchet metric holds at 4 per mille. `IndexAccess` left the node-class rows of the give-up table; its 8 now read `index read needs the element type this pass does not keep`. `tests/frontend/list_index_read.orb` and its golden were written before the rule and matched on the first run. The frontend gate is 43/43.

- **A field read of an `object` answers `object`.** `{ count: 3 }.count`, and `o.n` under a receiver the program calls `object`, answered `unknown`. `compiler/ir/builder.orb:4804` allocates the register for that same read as `object`, so the pass refused an answer it already gives elsewhere. The read answers `object` now. Which key the run time finds is a different question, and the pass claims nothing about it. Over the corpus the census reads 454 unknown over 102,961 instructions -- **0.4%**, and the ratchet metric moved 5 to 4 per mille. E2004 member reads fall 44 to 23, E2001 loads 244 to 235 and E2002 binary operands 54 to 53: the value bound to a typed read feeds both. The five per-code counts still sum to the total and the silent count is 0. `tests/frontend/object_field_member_read.orb` pins the text; it was written before the rule, its register numbering was wrong, and the text matched once the numbering was corrected. The frontend gate is 42/42.

- **`pop` yields an element, like `get`.** `compiler/ir/builder.orb:1999` answers `pop` from the receiver's element type beside `get` and `at`, and `compiler/front/sema.orb:4636` groups the three together; this pass knew the first two and not the third. Over the corpus `.pop` was 26 untyped calls and is 4: 22 of them had a `list<T>` in front of the dot. The census reads 485 unknown over 102,961 instructions -- 0.5%, and the ratchet metric holds at 5 per mille, because 26 instructions off a 102,961-instruction denominator does not cross to the next integer. E2005 calls fall 165 to 143 and E2001 loads 248 to 244. The five per-code counts still sum to the total and the silent count is 0. `tests/frontend/list_pop_call.orb` and its golden were written before the rule and matched on the first run.

Language front end:

- **A `+` with a string on either side is a concatenation.** The pass knew the comparisons, the bitwise operators and the case where both operands carry the same type; it did not know the one the build path spells out at `compiler/ir/builder.orb:5420` -- the emitter lowers it to `orbit_string_concat` whatever the other operand is. So `"count=" + n` answered `unknown`, and with it 84 `+` instructions of the corpus. Over the corpus the census reads 511 unknown over 102,961 instructions -- **0.5%**, 5 per mille, down from 6. E2002 binary operands fall 107 to 54 and E2001 loads 252 to 248. The five per-code counts still sum to the total and the silent count is 0. `tests/frontend/string_concat.orb` and its golden were written before the rule and matched on the first run. What is left of the class is `+` between an operand the pass cannot read and something else: no rule answers it, and inventing one would be the lie the count exists to show.

Language front end:

- **A library function writes its result payload.** `base64Decode` and `hexDecode` answered a bare `result`, so nothing could say what a later `try` yields: 19 of the corpus's `try` give-ups were that. They now answer `result < string >`, which `df40323` made possible to write. Eight of the 19 stopped being give-ups and 11 became the class behind them, `a handler that falls through needs a merge value`. Over the corpus the census reads 568 unknown over 102,944 instructions -- 0.6%, and the ratchet metric stays 6 per mille because the corpus grew with the spelling. The silent count is 0 and the five per-code counts still sum to the total. `parseIntChecked` and `parseFloatChecked` were spelled too and went back: `ok` admits only a string or an object, so `result < int >` cannot be written -- measured, not assumed. Two counts in `docs/KNOWN_LIMITATIONS.md` moved with this: 42 signatures and no payload, read with a pattern that could not see the formatter's `result < string >`, are 40 and 3 read correctly.

Language front end:

- **A payload written on a `result` reaches the C backend.** `-> result<string>` parsed, and nothing else worked. `ok("x")` answers a bare `result`, so the checker refused the signature, and the backend compares the type text with `"result"` exactly, so the local holding the value came out `void*` and the unwrap read `.value` off it. The builder now spells a result's IR type `result` whether or not the annotation names a payload -- one struct either way, the same rule `annotationBaseType` already applies to a list -- and the checker accepts a bare `result` value against a signature that names a payload, and the other way round. The annotation stays where it can be read: the frontend pass sees the source text, so `result<string>` is now something a `try` can be typed from. `tests/suite/result_payload_written.orb` is the program, written before the change and failing: it did not build, and it runs with exit 0 now.

Language front end:

- **The give-up tally now names the file.** "What the front end gives up on" printed one count per class, so 93 `try` give-ups looked like one rule failing everywhere. The census prints the largest single (file, class) pairs beside the tally. Measured 2026-11-04: `Match` is `compiler/ir/builder.orb` 58, `compiler/front/sema.orb` 48, `compiler/emit/c_backend.orb` 41 and `compiler/tools/doctor.orb` 29 -- four files that pattern-match on AST nodes, which is the class, not a defect in those files -- and the 93 `try` give-ups are 19 + 17 + 15 in three `tests/std` files whose `try` reads a result this pass does not answer. E3001 stays 462 and the unknown count is unchanged at 576 of 102,668 instructions, 0.6%; this changes what is measured, not what is typed. The class list's `Match` figure moved 306 to 307 because `compiler/tir/lower.orb` is in the corpus it measures and grew a rule the same day.

- **`system` is a receiver the checker names.** `system.uptime()` loaded `system` as a value, reported E2001 for the load and E2005 for the call, because no corpus file declares that name. `compiler/front/sema.orb` resolves the identifier to type `system` and answers `int` for each of its ten methods, so this pass reads that answer and a local of the same name still wins, the way the checker reads it. `tests/frontend/system_method_call.orb` and its golden were written before the rule and matched on the first run. Over the corpus the census reads 576 unknown over 102,668 instructions -- **0.6%**. E2001 loads fall 287 to 260 and E2005 calls 176 to 165. The five per-code counts still sum to the total and the silent count is 0. The ratchet metric stayed at 6 per mille: the count fell 38 and the corpus grew 72 instructions, because the pass that measures is inside what it measures. What is left of the calls is 160 methods on a list written with no element kind inside, where `unknown` is the answer and not a gap.

- **`ok` and `err` are known by name.** `return err("nope", 1)` lowered its callee as a `load` of `err`, a name no corpus file declares, and reported E2001 for the load and E2005 for the call after it. The checker accepts both names without a declaration, and two modules already answer what they return: `compiler/ir/builder.orb:389` and `compiler/emit/c_backend.orb:4622` both answer `result`. This pass reads that answer, and the name travels on the call: `call result err v0 v1`. `tests/frontend/err_call.orb` and its golden were written before the rule and matched on the first run. Over the corpus the census reads 614 unknown over 102,596 instructions -- **0.6%**, 6 per mille. E2001 loads fall 362 to 287 and E2005 calls 226 to 176. The five per-code counts still sum to the total and the silent count is 0. What is left of the calls is 171 methods on a list the source wrote without an element kind, where `unknown` is the answer and not a gap. The ratchet baseline moved down to 6.

- **A list write returns nothing.** `xs.push(7)` typed as a call answered nothing, because the method table knew `len`, `indexOf`, `get`, `at` and `slice` and no write. The build emits a list write as a statement block that calls `orbit_list_push` and gives no register a value. The answer was therefore already written, and only this pass had not read it: `push` and `set` answer `void` on `list` and on `list<T>` alike. `tests/frontend/list_push_call.orb` and its golden were written before the rule and matched on the first run. Over the corpus the census reads 739 unknown over 102,646 instructions -- **0.7%**, 7 per mille. E2005 calls fall 621 to 226 and E3001 give-ups go 461 to 462. The five per-code counts still sum to the total and the silent count is 0. `.push` was 375 of the 621: it was the largest single callee the new `CALL` line named the same day, so the instrument found the answer before this commit used it. The ratchet baseline moved down to 7.

- **E2005 names what it called.** The diagnostic said only "cannot type the result of this call", so the largest class of untyped instructions was the one class the census could not sort: 621 calls on 2026-11-04 and no way to say how many were a missing declaration and how many a method on an untyped receiver. The message ends with the callee as the source writes it -- a name, or `.field` -- and the probe prints one `CALL` line per distinct callee. The driver sorts them by what would have to answer, the same way it already sorts the E2001 loads and the E2004 fields, and the sorted total is checked against the E2005 count. Measured: 566 of the 621 are `.push` 375, `.get` 126, `.pop` 26 and `.set` 21 -- a method read off a receiver with no type, which no declaration fixes -- and 55 name nothing the corpus declares, led by `err` 37 and `ok` 13. The unknown count does not move with the message: 1,134 over 102,646 instructions, 1.1%, and the silent count stays 0.

- **A model name in call position is the model.** `Token(tag, text, line)` lowered its callee as a `load` of `Token`, a name no function declares and no binding holds, so it reported E2001 for the load and E2005 for the call that followed it. The model's own name is what the construction returns, and the program declares that name in the file it imports or in the file it is written in. The name travels on the call now: `call Token Token v0 v1 v2`. A model name read without calling it stays a value nobody binds and keeps E2001. `tests/frontend/model_ctor_call.orb` and its golden were written before the run, and the golden matched on the first one. Over the corpus the census reads 1,134 unknown over 102,644 instructions -- **1.1%**, 11 per mille. E2001 loads fall 689 to 362, E2005 calls 852 to 621, E2004 member reads 99 to 44 and E3001 give-ups 488 to 461. The five per-code counts still sum to the total and the silent count is 0. The loads that read a name only an imported file declares are gone: `Token` 54 and `LiteralNode` 21 were that bucket. The write that needed a typed receiver follows the same answer, so the give-up table prints no `MemberAccess` row today. The ratchet baseline moved down to 11.

- **A qualified construction names the type it builds.** `ASTNode.Literal(node)` lowered its callee as a read: a `load` of `ASTNode`, a name no function binds, and then a `member` of `Literal` on top of the call. The name before the dot is a declared type, and the name after it is one of that type's payload-carrying variants. The pass records those qualified names in a construction table now, so the call carries the name the source wrote: `call ASTNode ASTNode.Literal v0`. A read of the same name without calling it stays unanswered, because a payload-carrying variant is a construction that needs its argument and a constant would invent one. `tests/frontend/union_variant_construct.orb` pins the text. Over the corpus the census reads 1,757 unknown over 102,785 instructions -- **1.7%**, 17 per mille. E2001 loads fall 832 to 689, E2005 calls 980 to 852 and E2004 member reads 227 to 99. E3001 give-ups go 487 to 488, because one file that used to lose a function to a give-up now lowers it. The five per-code counts still sum to the total and the silent count is 0. What remains in the import bucket is a model name called without a dot -- `Token(...)` 54 and `LiteralNode(...)` 21 -- which is the same read, one hop away. The ratchet baseline moved down to 17.

- **A field declared `list<T>` carries its element kind to the read.** `declaredFieldType` answered the bare `list` for `items: list<string>`, because a list literal answers the bare `list` and the two were read as one claim. A literal writes its elements and no type; a field writes the type, so the two answers are not the same claim and the field's own text is now the answer. `bag.items.get(1)` reads `member list<string>` and then `call string`, and `tests/frontend/list_field_element_read.orb` pins that text with its golden written first. The unknown count falls 4,050 to 2,156 over 103,008 instructions -- **2.1%**, 21 per mille: E2001 loads 1,619 to 832, E2005 calls 1,353 to 980, E2004 member reads 812 to 227 and E2002 binary operands 266 to 117. The five per-code counts still sum to the total and the silent count is 0. A typed read is a bound value, so the loads and the operands of a list field fall with it rather than only the read. The ratchet baseline moved down to 21.

- **An element of a list carries the kind its type text writes.** `xs.get(0)` on a `list<int>` answered nothing, and `xs.at(0)` answered `string` whatever the receiver was. The rule was read from string sites and never asked what the list held. A type text that writes `list<int>` names its element, so `get` and `at` answer `int` and `slice` answers `list<int>`. A receiver typed the bare `list` still answers nothing; the source wrote no inside, and an invented element type is the lie the `unknown` count exists to make visible. `tests/frontend/list_element_read.orb` pins the text, predicted before the rule. 33/33 fixtures match. Over the corpus the census reads 4,050 unknown over 102,971 instructions -- **3.9%**, 39 per mille. E2005 falls 1,586 to 1,353, E2001 1,930 to 1,619, E2002 394 to 266 and E2004 920 to 812. The instruction total rises because this pass is itself in the corpus and `compiler/tir/lower.orb` grew. The five per-code counts still sum to the total and the silent count is 0. The ratchet baseline moved down to 39.

- **A method call carries its method, not a read of one.** `xs.indexOf(2)` lowered its callee as a `member` read of `indexOf` on the list and then called the result. No table types that read, so one source expression entered the census twice -- an unknown `member` instruction (E2004) and the unknown `call` after it (E2005). The member name now travels on the call, the way `print` already did (`call void print v0`), with the receiver as its first operand. `tests/frontend/method_call.orb` pins the shape, predicted before the rule; 32/32 fixtures match. Over the corpus 1,445 of those phantom reads disappear: E2004 falls 2,446 to 920, the unknown count 6,356 to 4,830 over 102,931 instructions -- **4.7%**, 47 per mille, with the five per-code counts still summing to the total and the silent count at 0. `get` and `at` still answer `unknown`, which is the element-kind table this pass does not keep. The ratchet baseline moved down to 47.

- **`NULL` is a value the front end names.** `compiler/front/sema.orb` resolves the identifier and `compiler/emit/c_backend.orb` gives it `void*`, so `if items == NULL` has always built. The lowering pass had no answer, so the name raised E2001 as an unknown identifier and the file printed no canonical TIR: 82 of those loads over the corpus. It answers `NULL` now, the string the build IR uses for the same value, which is how `object` and `result` are already reported, and `typeOfExpression` answers the same so a binding to one loads back what it is. `tests/frontend/null_literal.orb` pins the text. E2001 falls 2,012 to 1,930 and the census reads 6,356 unknown over 105,469 instructions -- **6.0%**, 60 per mille, with the five per-code counts still summing to the total and the silent count at 0. The ratchet baseline moved down to 60.

- **The string primitives the runtime provides are declared once.** `orbit_string_len`, `orbit_string_slice` and `orbit_string_indexOf` were declared wherever someone needed them first -- two in `std/sys/crypto/jwt.orb`, one in `std/string/string.orb` -- and a compiler module that called one without importing that file built fine, because the C backend emits the prototype anyway. `orbit frontend` had no such mercy: the name had no declaration in the program it was reading, so it reported E2001 and the file printed no TIR. They are declared in `compiler/host/extern.orb` now, beside the 37 others, and the five compiler modules that use them and imported nothing (`front/literal.orb`, `front/resolver.orb`, `host/pipeline.orb`, `tir/format.orb`, `tools/doctor.orb`) import that module. `literal.orb` stays a leaf in the graph the F-0004 fix depends on: `extern.orb` carries declarations and imports nothing. Over the corpus the census reads 6,438 unknown over 105,469 instructions -- **6.1%**, 61 per mille. E2001 falls 2,907 to 2,012, E2005 call results 2,037 to 1,586 and E2002 binary operands 533 to 394; the loads whose name lives in a file the importer does not import fall from 473 to 9, which is the measurement of this change by itself. The five per-code counts still sum to the total and the silent count is 0. The fixed point converged to the committed canonical, so no promote was needed: the generated C already carried these prototypes.

- **A union variant without a payload is a constant too.** `Shape.Square` names a value whose type is the union's own name; only its sibling `Shape.Circle(int)` needs an argument. The type table now records the payload-less variants of `enum` and `union` alike, and the qualified read emits `const Shape Shape.Square`. A variant that carries a payload stays unanswered: `ASTNode` 79, `Token` 54 and `LiteralNode` 21 unknown loads are exactly that class. Over the corpus the census reads 7,923 unknown over 105,469 instructions -- **7.5%**, 75 per mille. E2001 falls 3,055 to 2,907 and E2004 member reads 2,650 to 2,446; the five per-code counts still sum to the total and the silent count is 0. `tests/frontend/union_variant_read.orb` pins the shape, predicted before the rule.

- **A broken import names the imported file.** Reading imports to type cross-file calls put a new failure inside the frontend: a file that does not parse contributes no declarations, and the pass swallowed its parse diagnostics. The importer then carried the blame -- `orbit frontend attrbroken/use.orb` answered `E2001 at 0:0: unknown identifier helper` for a name the broken file never got to declare. The import walk now records the reason, and the refusal says `E1000 at 0:0: imported file .../inner.orb:3: unexpected token 'CloseBrace'`. A build still refuses a broken import outright (`compiler/host/pipeline.orb`); this only fixes who the message names. `scripts/cli_probe.py` carries the case (91 cases): the refusal must name the imported file and must not name the importer's call. Over the corpus the census reads **7.8%** (8,274 unknown over 105,585 instructions) and the ratchet stays at 78 per mille; the five per-code counts still sum to the total and the silent count is 0.

- **A variant of a declared enum is a constant, not a read.** `TokType.EOF` lowered as a load of `TokType` and then a member read, and the load had no binding to answer: E2001, and with it the file's whole canonical text. An enum now enters the type table with its variants as fields, and the qualified name emits `const TokType TokType.EOF` -- the type and the variant spelled as the source spells them. A union is not collected: a union variant is a construction with a payload, and claiming a constant for it would invent a value this pass cannot build. Over the corpus the unknown count falls from 9,620 to 8,261 over 105,512 instructions: **7.8%**, 78 per mille. E2001 falls 3,745 to 3,053 and E2004 member reads 3,313 to 2,644; the five per-code counts still sum to the total and the silent count is 0. `tests/frontend/enum_variant_read.orb` pins the text, predicted before the rule. `scripts/baselines/unknown_count.json` moved down to 78 with `--write-baseline`.

- **A call into an imported file is typed.** `orbit frontend` filled the signature and model tables from the one text it was handed. A call into an imported function was therefore an unknown identifier: E2001 on the load of its name. `tirCanonical` prints nothing while an error-severity diagnostic exists, so the whole file's text was suppressed for a name one `import` away. The entry point now reads the file's `import` lines at any depth and registers their signatures and models before lowering any body. Imported bodies stay unlowered: the printed text belongs to the file named on the command line. `tests/frontend/imported_signature.orb` pins that boundary, eight lines and no block for the imported function. A name behind an import that cannot be read keeps the answer it had, so a file that printed TIR still prints it. Measured on the same tree: with the imports lowered away the census reads 17,410 unknown over 105,754 instructions (**16.5%**), and with them it reads 9,620 over 106,122 (**9.1%**). The largest load still without an answer is `TokType` with 582: an enum is a `TypeDeclNode`, which the signature collector declares that it does not arm.

- **An anonymous model literal is a construction too.** `{ x: n, y: 2 }` had no rule, so its 12 uses over the corpus gave up with `expression cannot be lowered to TIR: ObjectLiteral` and the name bound to one loaded back `unknown`. It emits `construct object 2 x v0 y v1` now, through the same helper the named form uses, and the reader of types answers `object` -- the type the build IR already gives it. The model it builds is not claimed: the builder infers that from the position, and this pass reads no inference. Over the corpus E3001 falls 680 to 669 and unknown 17,410 to 17,388 of 105,644 instructions, still **16.5%** and 165 per mille. E2004 rose 4,556 to 4,560 and `Match` 300 to 301, because lowering a literal exposes what sits inside it. `tests/frontend/object_literal.orb` pins the text, predicted before the rule existed and matched line for line. The gate reads 27/27.

- **A field's declared type is read from the file, not only from a builtin.** `declaredFieldType` answered `int`, `string`, `bool` or `float` and returned nothing for every other spelling. In `o.i.n` the read of `i` entered the census as `unknown` (E2004), and the read under it was never reached. `bag.items` on a `list<string>` field answered `unknown` while a list literal answered `list`: two readers, two answers for one value. It answers `list` now, with or without the element type written, and the name of any model this file declares. `collectModels` fills that table before any body lowers, so a `model` written underneath the function that reads its field is in it. Over the corpus: unknown 17,702 to 17,410 of 105,554 instructions -- **16.5% from 16.8%** -- E2004 4,859 to 4,556 and E3001 682 to 680; the ratchet baseline moved to 165 per mille. `tests/frontend/nested_field_read.orb` and `tests/frontend/list_field_read.orb` pin the two new answers. `tests/frontend/crossfile_field.orb` pins the boundary: a model declared in an imported file is not a name this file declares, so its read keeps E2004 and its file keeps no canonical text. The gate reads 26/26.

- **A binding's annotation is read before its value.** `checkVarDecl` resolved the written type after checking the value. `val o: Option<int> = Option.None` -- the form E1006's own help text names -- was refused: the member read had no position to ask, and the variant carries no payload to decide it. The annotation resolves first now. Measured with `orbit check`: `val none: Option<int> = Option.None` and `val empty: Option<int> = Option.None()` gave 2 E1006 blocks before and no errors after. `val x: Option<int> = Option.Some()` answered E1006 before. It now answers `Variant 'Some' declares 1 payloads, but the construction passes 0.` (E1003), because the construction is finally read against `Option_int`. `tests/std/test_option.orb` and `tests/suite/generic_union_option.orb` each gained the annotation-only case, `tests/negative/n126_generic_union_annotated_empty_construction_reaches_arity.orb` pins the arity refusal, and the corpus is 115 programs (gate reads 115/115). The lists in `docs/SYNTAX_GUIDE.md` and `docs/ERROR_CODES.md` already named a binding's annotation as one of the positions that write a type; the checker now agrees with them.

- **One refusal prints once.** `take(Option.None())` against an `int` parameter printed `E1006` four times in two sentences: the `Call` arm read the callee's member as a value before deciding the construction, and `checkCallArgTypes` ran `checkNode` over every argument a second time. The call arm now asks `calleeIsTemplateConstruction` and reads only the object, and `checkCallArgTypes` takes the types the call site already computed. Measured with `orbit check` on the pinned program: 4 `error[E1006]` lines before, 1 after, exit 1 both times. `tests/negative/n125_generic_union_empty_construction_in_an_argument_prints_one_refusal.orb` pins it with a new header directive, `one-diagnostic:`, because a substring match passes on a refusal printed four times. The gate read 113/114 with the old checker and 114/114 with the new one; the corpus is 114 programs.

- **A call is typed from every declaration in the file, not only the ones already read.** The frontend registered a function's return type when `lowerFunction` reached it, so `later(n)` in a file that declares `later` underneath `useIt` had no answer: the load reported E2001 `unknown identifier`, an `if` around such a call reported E2100, and `tirCanonical` prints nothing while an error-severity diagnostic exists -- so the file's whole text was suppressed by the order of two declarations. `collectSignatures` reads the declaration list before any body now, and the answer is the text the source wrote. Over the corpus: unknown 19,302 to 17,702 of 105,423 instructions -- **16.8% from 18.3%** -- E2001 8,610 to 7,680, E2004 4,858 to 4,859, E2100 160 to 88, E2003 0 reported (was 2), E3001 681 to 682. `tests/frontend/forward_call.orb` pins the two-instruction lowering and `tests/frontend/undeclared_callee.orb` still pins that an undeclared name keeps its E2001. The baseline moved to 168 per mille.

- **One join makes every instance name.** Five loops still built `Box` plus `int` into `Box_int` -- two in `compiler/front/sema.orb` (`resolvedGenericTypeName`, the generic-literal name) and three in `compiler/ir/builder.orb` (`modelInstanceName`, the model registration loop, `fnInstanceName`) -- after `c85b128` had already collapsed the union pair into `literal.orb`. They are one function now, `instanceName`, beside `mangleTypeArg`, and a caller that holds binding rows takes the tail before calling: the row format belongs to the caller, the join does not. `mangleTypeArg` has no caller outside `literal.orb`.

- **`try` names the type it is missing.** `try f() catch { ... }` in expression position had no rule and reported `expression cannot be lowered to TIR: Try` -- 93 over the corpus. It lowers when the callee writes the payload inside its `result` (`-> result<string>`): `result_is_ok` tests the value, `branch` splits the block the source wrote, `result_unwrap` reads the payload in the ok path, and the handler is lowered in its own block. The 93 of this corpus all write a bare `-> result`, so the count is still 93 and the message now says `try needs the value type written inside the result, which this pass does not keep`. `tests/frontend/try_expression.orb` pins the lowering with both blocks; the gate reads 22/22.

- **n124 pins the second refusal a payload-less variant can print.** `compiler/front/sema.orb` answers `E1006` for that case from two sites with two sentences, and the construction site looked unreachable from a probe of `val x = Option.None()` -- which was an incomplete probe: that program prints BOTH sentences. `val x = Option.Some()` fires the construction text alone, because the member-read guard answers false for a variant that declares a payload. `tests/negative/n124_generic_union_empty_construction_needs_a_written_type.orb` pins it; the corpus is 113 programs and the gate reads 113/113. The double refusal of `Option.None()` is not pinned, and the section says so.

- **A field read is typed from the model the file declares.** `d.x` answered `unknown` unless the field was called `len`, so every member read entered the census as an `unknown` instruction and E2004 reported it: 5,389 over the corpus, the second-largest source, and enough on its own to suppress the canonical text of any file that used one. `lowerProgramToTir` now collects the program's own `model` declarations while it lowers (`TirType`/`TirField` in `compiler/tir/format.orb`, unread by the printer), and `declaredFieldType` answers the written type when it is `int`, `string`, `bool` or `float`. A field whose type names another model, a list or a union still answers `unknown`: that needs the same table one level deeper, and guessing from the field's name is the failure the census was built to keep visible. Unknown instructions 20,350 to 19,300 -- 18.3% of 105,403, from 19.3% -- with 1,050 reads typed, 286 dependent loads among them, 204 binary operands and 31 unary operands no longer unknown, and `E3001` at 681. `scripts/baselines/unknown_count.json` is rewritten at 183 per mille. `tests/frontend/field_read.orb` pins the printed text, predicted before the rule existed and matched line for line; the gate reads 21/21.

- **`return ok` is a wrapper the frontend lowers.** `return ok 200 "ready"` reached the expression reader as `ReturnOk` -- the statement reader knew `return <expr>` and not the `ok` form -- 8 times over the corpus, and the give-up suppressed its file's canonical text. It emits `result_ok result 200 v0` and then `return unit v1`: the name the build IR already gives the wrapper, the status code the source wrote, and `void` as the operand when the `ok` carries no payload, because the parse keeps the empty expression instead of dropping it. `E3001` falls 688 to 680, the instruction total rises to 105,285 and the unknown count is 20,350 -- 193 per mille, the same rate, because the two new `unknown` instructions arrive with 25 new typed ones. `tests/frontend/return_ok.orb` pins the text; the gate reads 20/20.

- **A model literal is a construction the frontend lowers.** `Point { x: 0, y: 0 }` had no rule, so 50 model literals gave up with `expression cannot be lowered to TIR: TypedLiteral` and the name bound to one loaded back `unknown` at every later use of it. It emits `construct Point 2 x v0 y v1` now: the type the source wrote, the field count, then each field and its value. The reader of types answers the same string, and that agreement is the half that removes the loads -- 73 of them stop being `unknown`, and four writes through a place lower as a side effect because their receiver was one of these literals (`MemberAccess` writes 216 to 212). A generic literal keeps the bare name the program wrote, not the `Box_int` the build mints: this text reports the source, and the checker owns the instance. Over the corpus `E3001` falls 742 to 688, the instruction total rises to 105,260 and the unknown count falls to 20,348 -- 193 per mille, and `scripts/baselines/unknown_count.json` was rewritten at that number with `--write-baseline`. `tests/frontend/model_literal.orb` pins the text; the gate reads 19/19.

- **An element write lowers: `xs[i] = v` emits `store_index`.** The assignment reader had a rule for a field place and none for an index, so 22 writes to an element gave up with `cannot lower this assignment to TIR: IndexAccess`. It lowers when the container's own type is one the pass can read, the same condition the field write carries: the alternative is to emit a load this pass cannot type, because it keeps no element table. 5 of the 22 stay give-ups under a receiver the pass cannot read, and the *read* `xs[i]` (8 cases) stays one for the same reason -- a load would have to say what it loaded. `E3001` falls 759 to 742 and the unknown rate holds at 194 per mille (20,421 over 105,091 instructions, from 20,419 over 105,036): the 55 instructions the new writes emit are typed. `tests/frontend/index_write.orb` pins the text; the gate reads 18/18.

- **One function mints an instance name.** `compiler/front/sema.orb` and `compiler/ir/builder.orb` each carried the seven lines that join `Option` and `int` into `Option_int`, and each of the two comments said the spelling was shared with the other side. It was not: the checker resolved a pattern through its own copy and the builder declared the tag set through its own, and a program whose two copies disagreed would pass `orbit check` and dispatch on a tag of a type it never wrote. The rule is `unionInstanceName` in `compiler/front/literal.orb` now, beside `mangleTypeArg`, which is the leaf both sides already import -- the same reason that module exists. `make promote-diff` reads 44,366 lines raw against **152** after flattening generated names, in 7 hunks across `o_mangleTypeArg`, `o_registerType` and `o_substituteTypeParams`: three bodies leave the canonical and one arrives. Five more copies of the loop stay in the model and generic-function paths (in `compiler/front/sema.orb` and `compiler/ir/builder.orb`), untouched here.

- **A generic union instantiates, and `Option` leaves quarantine.** `union Option[T] { Some(T) None }` was refused at the declaration: nothing substituted `T`, so a payload declared `T` reached the C backend as the parameter's own name. The argument now comes from a position that writes a type -- a parameter's declared type, a binding's annotation, a `return` in a declared function, a call argument against its parameter -- or from the payload a construction hands over, and each argument list declares one instance with its own tag set. `tests/suite/generic_union_option.orb` builds `Option<int>`, `Option<string>` and `Pair<int, string>` in one program and exits 0; `tests/negative/n118_generic_union_needs_a_written_type_for_none.orb` pins the refusal of a payload-less `None` that no position writes. The module ships as `std/option/option.orb` with `tests/std/test_option.orb` over the four written positions, importing the union from another file -- the position a std module needs. `tests/std/test_imports.orb` merges it with the rest and gains `std/sys/arena.orb`, the one module it had never imported, so all 21 of 21 now compile into one program. `std/quarantine/` is empty. The counts move with it: `std/` 20 to 21 modules, `tests/std/` 23 to 24 files (24/24 green), `orbit fmt` 210 to 212 sources. The emitted C moved at the feature commit: 69,344 lines raw against **3,334** after flattening generated names, 122 hunks across 23 functions, with parity 33/33 and no golden touched.

- **A file-scope directive has no code to emit, and now says so.** `migrations "CREATE TABLE ..."` and a `port 8080` config line had no arm in `lowerProgramToTir`, so each reached `E3000: top-level declaration cannot be lowered to TIR: MigrationDecl` -- 3 over the corpus, the whole of `E3000`. `E3000` carries severity error and `tirCanonical` prints nothing when any error exists, so a program with a migration had no canonical TIR at all for a declaration that holds no code. They lower to nothing now, the way a file-scope `const` already does; `E3000` reads 0 on the corpus and the unknown rate is unchanged (20,005 over 103,333 instructions, 194 per mille) because a give-up was never an instruction. A `schedule` is not on the list: its handler is a body. `tests/frontend/directive_decls.orb` pins the text, the golden of a file that used to print nothing; the gate reads 17/17.

- **An interpolated string is parts the frontend lowers.** `"count=${n}!"` had no rule, so the whole literal was one give-up -- 12 over the corpus, `expression cannot be lowered to TIR: Interp` -- and the error suppressed its file's canonical TIR. It emits `interp string <count> <raw|unescaped> <values>` now: the text between the holes is a `string` const, each hole is the value of its own expression, and the flag says whether the chunks are read verbatim or unescaped. That reading belongs to the build, and this pass does not copy the unescape rule -- a second answer to one question is the defect class `docs/KNOWN_LIMITATIONS.md` records four times. `E3001` falls 762 to 750; the unknown rate holds at 194 per mille (20,005 over 103,333 instructions, from 20,003 over 102,736). `tests/frontend/interp_parts.orb` pins the text; the gate reads 16/16, and the fixture writes its hole as `$` because the lexer reading the fixture's own literal would interpolate a real `${`.

- **`for x in 0..n` is a loop the frontend lowers.** The statement lowering had no arm for a `for`, so all 46 in the corpus fell to the expression reader as `... TIR: For` and suppressed their file's canonical TIR. A range counts an int between its bounds, so it lowers to the `while` form -- condition, body, exit -- plus an increment block, which is where a `continue` lands: jumping to the condition with the counter unchanged repeats one item forever. The item and the `for x, i` index bind to `int`, and the bounds are read once before the loop. Over a list the item's type is the element kind and this pass keeps no element table, so that path stays a give-up and says which it is (20 cases), as does a labelled loop (4). `E3001` falls 779 to 762 and 22 more loops are typed; lowering a body exposes what is inside it, so `Try` 92 to 93 and `TypedLiteral` 49 to 50. The unknown rate holds at 194 per mille -- 20,003 over 103,267 instructions, from 19,977 over 102,736. `tests/frontend/range_loop.orb` pins the text and `list_iteration.orb` the suppression; the gate reads 15/15.

- **`break` and `continue` jump where the loop put the blocks.** Neither had an arm in the statement lowering, so both fell to the expression reader and reported `... TIR: Break` (91) and `... TIR: Continue` (26), suppressing the file's canonical TIR. The enclosing `while`'s exit and condition blocks now ride down the statement lowering; outside a loop there is no block to name, and the give-up says so. `E3001` falls from 896 to 779 with those two classes gone, and the unknown share holds at 19.5% -- the jumps answer `unit`. `tests/frontend/loop_exit.orb` pins it; the gate reads 13/13.

- **A bare `return` is not an unlowerable expression.** `fn shout() { return }` sent the return's empty value to the expression reader, which reported `expression cannot be lowered to TIR: Empty` -- 279 over the corpus -- and the error suppressed the file's canonical TIR. It emits `return unit void` now. `E3001` falls from 1,175 to 896 with the `Empty` class gone, and the unknown share holds at 19.5%: the new instruction answers `unit`, so nothing entered the count either way. `tests/frontend/bare_return.orb` pins both cases; the gate reads 12/12.

- **`[1, 2]` is a value the frontend lowers.** A list literal had no rule: the elements were never lowered and the name bound to one loaded back `unknown`, because the reader of types and the lowerer disagreed about what the value was -- 412 give-ups and 780 unknown identifier reports, and the canonical text suppressed in every file that used one. It emits `list`, and both readers answer `list`; the element kind is not claimed, because the pass keeps no table for it. Over the corpus `E3001` falls 1,586 to 1,175, `E2001` 9,573 to 8,793, unknown 20,747 to 19,977 and the share 20.3% to 19.5% (baseline 194). `tests/frontend/list_literal.orb` pins both halves; the frontend gate reads 11/11.

- **A write through a field lowers: `d.x = 2` emits `store_field`.** The statement reader had no write rule for a place, so the assignment was a give-up and the diagnostic suppressed the file's canonical TIR. It lowers when the place's own value is typed; a chained place under a receiver this pass cannot type stays a give-up, because emitting it would swap a declared give-up for an `unknown` instruction. `E3001` falls from 1,784 to 1,586 -- 198 simple place writes lower, 216 chained remain -- the instruction total rises to 102,035 and the unknown share falls to 20.3% (baseline 203). `tests/frontend/field_write.orb` pins the text; the frontend gate reads 10/10.

- **A declared function's name is not an unknown identifier.** The load of a callee read only the
local bindings, so `take(x)` raised `E2001 unknown identifier take`, and because `tirCanonical`
prints nothing while a diagnostic of severity error exists, a file that called its own functions
printed no canonical TIR at all. The name is now read from the program's declaration. Over the
corpus: 20,747 unknown instructions against 23,529, the share 20.4% against 23.2%, E2001 from
12,343 to 9,573, baseline 204. An empty answer is never assigned over `unknown`, so an undeclared
name still errors: `tests/frontend/undeclared_callee.orb` pins the suppression, and
`tests/frontend/assign_statement.orb` pins the TIR the callee rule made reachable. The frontend
gate reads 9/9.

- **`x = 5` is lowered as a statement.** The statement walker handed every node it did not recognise to the expression reader, which has no assignment rule, so an assignment became `E3001: expression cannot be lowered to TIR: Assignment` and nothing else was emitted for its value. It now emits the same `bind` a `val` uses and re-reads the name's type from the binding. 2,723 of the 3,137 assignment give-ups are gone; the 414 left write through a place (`a.b = e`) and say `cannot lower this assignment to TIR: MemberAccess`. Over the corpus the instruction total rose to 101,639 from 88,110 because those values are lowered now, and the unknown rate fell to 23.2% (231 per mille, from 241) -- the ratchet reads the rate, and the baseline moved down with it.

- **The frontend says which expression it gives up on.** `E3001` and `E3000` printed one sentence for every unsupported node, so the census reported 9,233 give-ups with no way to scope them. `astNodeKind` names the node class in the message and `unknown_census.py` tallies by class over the corpus. Naming it found the largest class was not a gap: 5,045 `Empty` hits came from `lowerStatement` handing every statement it did not recognise to the expression reader, and an empty statement has no instruction to emit. It lowers to nothing now, and `E3001` reads 4,468 with `Assignment` (3,137) the real gap left.

- **A call's type comes from the program's own declaration.** The frontend reader answered a call only for names written into `compiler/tir/lower.orb` -- `tirIntText`, `isVisited`, `hasErrors` each had their own line -- and every other call came back `unknown`, and so did every `val` bound to one. `declaredReturnType` reads the function the file declares instead: the census over 209 files and 88,108 instructions went from 25,489 `unknown` instructions (29.1%) to 21,227 (24.1%) -- `call` 6,756 to 4,259, `load` 12,670 to 11,284 -- and the ratchet baseline moved down with it. A call into another file is still `unknown`: the lowering sees one module's declarations.

- **A `match` binding keeps its payload type.** Every arm binding was declared `unknown`, because the checker read the payload from a registry keyed on the variant name alone and had no owner to ask. The arm now declares each name with the payload its resolved owner declares, so `shout(n)` with `n` an int is `E1005` and `n.name` says `int` has no member `name`. `tests/suite/match_binding_payload_type.orb` reads an int, a string and a model through one union; `tests/negative/n122` pins the refusal. The compiler's own 241 match arms still typecheck: the fixed point converges.

- **Two unions may declare the same variant name.** `Signal.Body("s")` was
  refused with `E1005` while `Body(3)` with both unions in scope was accepted:
  the registry is keyed on the variant's own name, so the first row answered the
  payload of either, and the constructor macro was named after the variant alone
  so a second `#define Body` replaced the first. Payload and arity now come from
  the owner the program wrote, a bare `match` pattern resolves through the
  scrutinee's type, and the constructor macro carries both names -- `cUserName(owner + "_" + variant)` where it read `cUserName(variant)`.
  A bare construction whose name belongs to two unions is refused with the new
  `E1011`, naming both owners. `tests/suite/union_shared_variant_name.orb` and
  `tests/negative/n121` pin the two directions. The emitted C moves, so the
  canonical moves with it: 2,039 lines after flattening register and label
  numbering, in 457 hunks across 58 functions. Parity reads 33/33 unchanged --
  no probe constructs a variant.

- **`union Name[T]` parses, and `E1006` names what is still missing.** The
  declaration arm of `parseTypeDecl` calls the same parameter-list parser the
  model, fn and trait arms always used, so `union Option[T] { Some(T) None }`
  reaches the checker instead of stopping at the `<`. Nothing substitutes an
  argument at a construction yet, so the checker refuses the declaration at the
  name's own line and column, which a type declaration could not do before
  `TypeDeclNode` carried a position. `enum` and `alias` parameter lists and a
  constrained union parameter are refused by the parser. Pinned by
  `tests/negative/n118`, `n119`, `n120`. `Option` stays quarantined until the
  substitution lands.

Commands and gates:

- **The census now measures the program the command line compiles.** `scripts/unknown_census.orb` lowered each file through `lowerProgramToTir`, which reads only the text it is handed, so it never saw an import while `orbit frontend` did. The probe calls the same entry point the CLI calls now. The numbers moved with it: E2001 7,663 to 3,745 loads, E2004 4,560 to 3,313 member reads, E2005 4,202 to 2,030 call results, and the chained `MemberAccess` give-up 211 to 37. `scripts/baselines/unknown_count.json` moved down to 91 per mille with `--write-baseline`, which is the direction the ratchet exists to allow. The entry above this one claimed the rate "holds at 16.5%": that was the old instrument measuring the old path, and the correction is here.

- **A skipped native gate now says why it cannot run here.** On Linux the three native gates told the reader to set `ORBIT_R6`; setting it turned three skips into three failures, because `orbit build --backend=native` refuses any host that is not Windows x86-64 (`hostIsWindows` in `compiler/host/pipeline.orb`). The gates skip on that rule now and name it, and the closing line of `dev.py` says the lane cannot run here instead of pointing at a variable. Measured on the 3904 MB host with `ORBIT_R6` set: 3 skipped, `all 0 gate(s) passed` and no `FAIL`; on Windows the same filter still runs `runtime_module_native` to 6/6.

- **The native lane runs against this branch, and what it still cannot do is declared.** With `ORBIT_R6` set, `dev.py all` runs 30 gates and all 30 pass: `suite_native` 125/125 with 2 declared ratchets, `suite_std_native` 24/24, `runtime_module_native` 6/6. It had been 106/125 and 22/24, because the union instances this cycle minted are named `Option_int.Some` and `Shape.Unit`, and orbit-r6 resolved a constructor by its bare name only (its D-M1-136). `system_http_requests_ok` and `system_http_requests_error` were missing from the
three lists that register a builtin: the IR extern declaration, the compile-time
predicate and the C return-type inference. The IR therefore called an undeclared
target and the native backend refused the program, while the C backend linked it
by name. The two programs orbit-r6 still cannot build are declared with their
causes: the DB subset rule it keeps, and a runtime symbol older than its pin.

- **A gate reads every `path:line` in the documents.** `doc_counts.py` re-computes a counted claim from the tree. Nothing read a location, and 125 of the 184 citations in the audited documents pointed somewhere else. Three of them: `runtime/arena.c:406`, in a file that is 174 lines since the arena split; `compiler/selfhost/pipeline.orb`, a path that has not existed for weeks; and `c_backend.orb` anchors that lagged its doubling. `scripts/cite_check.py` answers MISSING, RANGE, BLANK and SYMBOL, skips fenced examples, and never checks a name the sentence did not write. 189 citations in 15 documents now match the tree; the self-test holds six properties, one of them the wrapped-line case the first version missed. T0, `alive_check` and the `static` CI job carry it, and `dev.py all` runs 27 gates where it ran 26.
- **`.r6-build/`, `fuzz_crashes/` and `.qoder/` are ignored.** `scripts/dev.py list` had been reading them as changed source, so a docs edit selected T2; `orbit doctor .` walked the fuzz cases, which is the tool state the scan exists to skip. Measured: 451 findings (143 errors) in 505 files with them, 448 (140) in 502 without.

- **`orbit doctor` stops paying 64 KB per quoted line.** `doctorCodePart` built each quoted run through a chunk buffer, and a buffer's first block is `ORBIT_CBUF_INIT_CAP` -- 65536 (`runtime/collections.h:189`) -- which the arena holds until the process ends. One scan, one line, one quote, 64 KB whether the run was 12 bytes or 60. Joining the runs with `+` asks for the bytes the text has. Measured on the lowest `ORBIT_ARENA_MAX_MB` that completes `orbit doctor compiler` over this repository: 3888 MB to 432 MB on an 8192 MB Windows host. `416` aborts there and `432` answers 141 findings in 28 files. On the 3904 MB Linux instance the scan aborted at exit 134 with 3070562304 of 3070620672 bytes committed against the 2928 MB default. It now answers those 141 findings at the default with `ORBIT_ARENA_MAX_MB` unset. `--scope-only` no longer splits the directory on either host, and the whole-tree scan reports 451 findings in 505 files on both. `docs/KNOWN_LIMITATIONS.md`'s first section was the requirement; it now records what fits, and the scoped arena the source can select stays the open item.

- **`orbit frontend` prints the document instead of dropping one in the directory.** With no `-o` the command wrote `orbit.tir` into the current working directory, so a read-only question left a file behind. It writes the canonical TIR to stdout now (measured: exit 0, 143 bytes on stdout, no `orbit.tir` created, from a scratch directory), `-o <path>` writes the file as before, and `-o` with no value is refused with one diagnostic and exit 2 instead of silently taking the default. Nothing in the tree depended on the old default: `frontend_gate.py`, `cli_probe.py` and `ENGINEERING.md` section 8 all pass `-o`.
- **No `unknown` instruction is silent; the census said 11,491 were.**
  `scripts/unknown_census.py` computed `unknown without diagnostic` as
  `unknown - (E2001 + E2002 + E2003)`, which left `member` and `call` out of
  the subtraction while the E2004 and E2005 branches of `compiler/tir/lower.orb` fire on
  each instruction it makes `unknown`. Counting all five codes,
  the 2026-11-01 run over 207 files and 87,591 instructions reports 25,489
  unknown and 0 with no diagnostic: 12,670 + 1,196 + 46 + 4,821 + 6,756. The
  census script did not change what the compiler does, so the compiler never
  had a silent class; the gate's `silent_per_mille` moved from 136 to 0 and
  `docs/KNOWN_LIMITATIONS.md` now names what the number guards.

- **Latency percentiles keep their meaning above 100 ms.** The histogram was
  1000 buckets of 100 µs and one overflow slot, so a 300 ms p99 and a 40 s p99
  answered the same value -- and that value was the single longest request, which
  is not a percentile boundary at all. Above 100 ms the buckets now double:
  100-200 ms, 200-400 ms, and so on to a final clamp near 14.6 h, which is the
  only slot still answered from the maximum. A 300 ms p99 reports 400 ms and a
  160 s one reports 204.8 s. Pinned by `runtime/test_latency_percentiles.c`.

- **A Windows stop drains instead of killing.** The graceful ask had no channel:
  `orbit_os_kill(pid, 1)` ran `TerminateProcess` on Windows like mode 0 did, and
  a detached child has no console to receive a Ctrl event. The server now opens
  `Local\orbit-stop-<pid>` at start, its worker loop polls that name after every
  `select`, and mode 1 sets it -- falling back to the old terminate only when no
  channel carries the pid, which is a child that never reached the server start.
  POSIX keeps SIGTERM and answers 0 from all three calls. Measured through the
  CLI: `orbit stop` returned in 193 ms with the service terminated, and 1108 ms
  now with the service printing `Server stopped.` after its workers join. Pinned
  by `runtime/test_stop_channel.c`.

- **`orbit stop` and `cluster down` wait now.** Both ask for a graceful stop and
  escalate to a kill three seconds later, but the wait was `clusterSleepSec`,
  which slept by spawning `timeout /T 1 /NOBREAK` -- and `timeout` refuses to run
  when its input is redirected, so each "second" returned at once. The documented
  three-second grace measured 193 ms for `orbit stop` and 306 ms for
  `cluster down`, across 11 call sites of that helper. The wait blocks this
  thread on `orbit_sleep_ms` now, and `orbit stop` measures 1074 ms. The service
  is still terminated on Windows afterwards: a detached child has no channel to
  ask, which is the remaining entry in Known Limitations. Pinned by
  `runtime/test_sleep.c` (lower bound only: an upper bound is a race with the
  rest of the machine).

- **`orbit migrate <file.orb>` runs migrations without serving.** It builds a
  migrate-only binary into `.orbit/`, runs the database block (forward, or a
  rollback when `ORBIT_MIGRATE_DOWN=<version>` is set) and exits with the
  result. Pinned by four cases in `cli_probe`.

- **`orbit doctor` skips what `.gitignore` names.** A `.gitignore` line that is
  just `name/` keeps that directory out of the scan, the way dot-directories
  already were. `orbit doctor .` over this repository scans 476 files instead
  of walking `scratch/` and `dist/`. Pinned by `doctor-skips-gitignored` and
  its un-ignored control in `cli_probe`.

- **`orbit frontend` lowers `print`.** The TIR path had no binding for it, so
  the first example exited 1 with `unknown identifier print`. The call now
  emits `call void print`, and every program under `examples/` produces TIR.
  Pinned by `tests/frontend/print_pipeline.orb` and its golden.

- **The existing commands finish without an r6.exe.** On Windows the native
  backend is the default only when `ORBIT_R6` names a path or `r6.exe` sits
  beside the compiler; otherwise the build uses the C backend and prints one
  line saying so. `orbit build`, `orbit run` and `orbit dev` all inherit it.
- **`orbit run dir/file.orb` starts the program on Windows.** cmd.exe read the
  quoted forward-slash path as a command named after its first segment; the
  child path now carries backslashes.
- **A compiler outside the checkout finds its trees.** `ORBIT_RUNTIME_DIR` and
  `ORBIT_STD_DIR` name the runtime and std directories before the compiler's
  own directory and the working directory. Missing runtime headers are
  reported before the C compiler runs, instead of as a missing C include.
- **`orbit frontend` names what it refused.** The command prints the error the
  frontend reported, or the first `unknown` type with its function and value
  id; it used to say diagnostics contained errors while printing none.
- **`orbit doctor` scopes route conflicts to one program.** A route belongs to
  the programs whose import closure reaches its file, so `orbit doctor
  examples` no longer reads five services' `GET /health` as one program's
  duplicates. The walk skips dot-directories, and module fingerprints are a
  fixed size.
- **`orbit build` reports `.text` on Linux too.** The footer read only PE
  images; it now reads ELF64 section headers, so the same program prints the
  same footer on both hosts.
- **The runtime archive names the host it was built for.** An archive built on
  Windows is stale on Linux instead of handing MinGW objects to the linker.
- **A POSIX checkout keeps LF.** `.gitattributes` pins `*.sh` to LF, so a
  Windows checkout no longer produces shell scripts that fail to parse on
  Linux.
- **`orbit cluster up` no longer holds the caller's stdout open.** On Windows
  the nodes inherited the compiler's stdout, so `orbit cluster up | tail`
  waited until every node exited. They start with their log file and nothing
  else from the caller.
- **A route binds as many path captures as its pattern names.** The request
  owns its capture table and grows it, instead of a 32-slot array that dropped
  the rest. `runtime/test_params_decode.c` asks for 40 and reads the last.
- **`orbit --version` prints `orbit 0.1.0`.**

Runtime:

- **A rewind refuses a checkpoint from another segment.** `orbit_alloc_try` moves `base` to a fresh reservation on the overflow path and leaves `generation` where it was, so an offset taken before one is a distance from a different base. `orbit_arena_rewind` compared only the epoch and the cursor, accepted such an offset, and put the bump pointer inside bytes the live segment had already handed out -- the next allocation returned them a second time. The arena counts the segment its cursor lives in, a checkpoint records it, and a mismatch is refused. Removing the rule in a scratch copy of `runtime/arena_checkpoint.c` makes the new test fail at `assert(!orbit_arena_rewind(arena, cp_first))` (`runtime/test_arena.c:272`), so the test is not vacuous. `runtime_c` reads 25/25 on Windows and 26/26 on Linux; `size` on the members moved `arena` 1 144 to 1 176 and `arena_checkpoint` 224 to 256, and `docs/STARTUP.md` records both and names the commit each `hello` row was measured at.

- **The ceiling line names where its number came from.** The refusal always ended with `MB from ORBIT_ARENA_MAX_MB`, so a process that never set the variable was told to unset a variable nobody had set; the number was three quarters of physical memory. The arena records which source produced its cap, `orbit_oom_put_ceiling` prints that wording, and a child inherits it with the cap. `runtime/test_arena.c` asserts both texts byte for byte, and forcing that wording back to the variable name fails the assertion at `runtime/test_arena.c:345`. `docs/ARENA.md` names both sources; the two `docs/KNOWN_LIMITATIONS.md` transcripts that print the old wording are dated 2026-11-02 runs and stay. `arena_alloc` grew from 3 016 to 3 172 `.text` bytes.

- **The arena test program counts its own runs.** It closed with `All 24 mandatory Orbit Arena runtime tests PASSED` while `RUN_TEST` listed 25, and nothing recomputed either number. The count now comes from the macro, and the line reads `All 25 ...` on the tree that made it (`grep -c 'RUN_TEST(test_' runtime/test_arena.c` prints 25).

- **The per-route ledger percentiles estimate inside their bucket too.** `/_ledger` keeps a second histogram, one bucket per power of two of handler cycles, and it answered the top edge of the bucket holding the rank: a 10 ms outlier reported 13421 us, the boundary above it. Each bucket now sums the cycles it received, and the estimate anchors on that mean and spreads by rank, clamped to the bucket -- the whole-server rule applied to the route table. The static state doubles, from 32 KB to 64 KB across the 64 route slots, and the table's own label now says `log2-bucket estimates`. `runtime/test_ledger_percentiles.c` pins the one-request case, a 100-request spread inside one bucket, both clamps and the JSON keys.

- **A latency percentile is estimated inside its bucket.** The histogram answered the upper edge of the bucket holding the rank, so a 300 ms p99 reported 400 ms -- the top of a 200-400 ms bucket, not the request. Each bucket now sums the microseconds it received, and the estimate anchors on that mean and spreads by rank, clamped to the bucket: one request in a bucket answers that request, a spread answers within one rank step. `runtime/test_latency_percentiles.c` pins the one-sample case, a 100-sample spread across the 200-400 ms bucket and both clamps. The per-route `/_ledger` percentiles still answer edges -- a second table, the same estimator still to apply. `docs/KNOWN_LIMITATIONS.md`, `docs/LANGUAGE_REFERENCE.md`, `docs/TOUR.md` and `docs/FAQ.md` followed.

- **A second server on an occupied port fails on Linux too.** The emitted
  listener called `orbit_enable_reuseport()`, which set `SO_REUSEPORT` on Linux
  only, so a second process bound the port and the kernel distributed
  connections between the two. Windows already refused it with
  `SO_EXCLUSIVEADDRUSE`. Nothing needed the sharing: cluster nodes take their
  own port (`--port-base`), and `orbit dev` waits for the child to die before it
  respawns. The call and the helper are gone, `SO_REUSEADDR` stays for the
  TIME_WAIT case, and `scripts/kynx_gate.py live` now starts a second server
  against the occupied port while the first is listening and fails unless it
  refuses. Measured before on WSL Ubuntu: the second process printed its own
  banner and was still serving (exit 124). Measured after: exit 1 with
  `Port 47812 is not available. Another program may be using it.` and one
  listener. Against the pre-fix emitter the new check reports `did not refuse
  it (exit -1, still-serving True)` and the gate exits 1.

- **Migrations roll back.** A `migrations down "<SQL>"` line undoes the
  forward migration at the same position. `ORBIT_MIGRATE_DOWN=<version>` at
  startup rolls back every applied version above it, newest first, removes
  their rows, and stops before the forward set runs. `-1` rolls back
  everything. Pinned by `runtime/test_migrations.c` and
  `tests/suite/migrations_down.orb`.

- **`std/json` parses and traverses, and has a test.** `parseJson` refuses
  malformed input as a whole and the `json*` getters read typed fields and
  indexed arrays. `tests/std/test_json.orb` pins the wrapper; the runtime half
  was already in `runtime/json.c`.

- **Requests are counted by class.** `system.http_requests_ok()` counts
  responses below 400 and `system.http_requests_error()` counts 400 and above,
  both recorded where the response is sent so the default router and the
  emitted one feed the same pair. `runtime/test_response.c` checks both.

- **A program refuses to start against a newer schema.** If
  `_orbit_migrations` holds a version the program does not declare, startup
  prints the version and exits non-zero instead of running old code against
  columns it cannot describe. Pinned by
  `runtime/test_migrations.c:test_newer_schema_is_refused`.

- **The runtime archive has one member per module, and a program starts only
  what it uses.** `hello.orb` built with the C backend has 13 072 bytes of
  `.text` (was 116 352), imports only KERNEL32 and msvcrt (was also ADVAPI32 and
  WS2_32) and has 8 736 bytes of `.bss` (was 4 892 672). The driver passes
  `-DORBIT_WITH_NET` and `-lws2_32` only for a program that uses the network;
  the generated `main` drops the ledger and string-pool calls and sets
  `argv`, the console mode and the crash handler only when needed. The native
  backend refuses an `r6.exe` that does not answer `--version` with a known IR
  protocol within 5 s, and stops an `r6.exe` build after 300 s
  (`ORBIT_R6_TIMEOUT_MS`). See [Program start-up](STARTUP.md).

Native backend:

- **`orbit build --backend=native` builds through R6, with no C compiler.**
  `--backend=c|native` and `ORBIT_BACKEND` choose the code generator for
  `build` and `run`; the flag wins. With `native` the build writes the
  `--emit-ir` document into the temp directory and runs `r6.exe` on it. R6 is
  found through `ORBIT_R6`, then `r6.exe` beside `orbit.exe`, then
  `bin\r6.exe` under the install root. The runtime archives come from
  `R6_RUNTIME_DIR`, set from `ORBIT_R6_RUNTIME` or the install's `lib\`. An
  R6 refusal is a compile error with R6's line verbatim and no fallback to C.
  `ORBIT_SKIP_CC` forces the C backend. The default is `native` on Windows and `c` elsewhere. Gates:
  `suite_native` and `suite_std_native` (skipped without `ORBIT_R6`).
  See [Commands](COMMANDS.md#backends-c-and-native).

Language:

- **A program may name its symbols after any C or runtime name.** The C backend
  emits every function, route handler, model, union, enum, constant and variant
  constructor as `o_<name>`, so `fn remainder`, `fn printf` or `model FILE` no
  longer meet `<math.h>`, `<stdio.h>` or the runtime. The libc list, the C type
  list, the `orbit_` prefix refusal and the generated runtime-name table are
  gone. Only a function named like a runtime function the compiler calls itself
  (`orbit_string_slice` for `text.slice(a, b)`) is still refused. Pinned by
  `tests/suite/c_names_user_defined.orb` and `tests/negative/n89_compiler_called_runtime_name.orb`.
- **`int` is 64 bits.** `orbit_int` is `int64_t`, so an `int` runs from
  -9223372036854775808 to 9223372036854775807 and wraps modulo 2^64. Literals
  up to 9223372036854775807 are accepted, and `-9223372036854775808` is the
  spelling of the minimum. The runtime follows: `orbit_int_to_string`,
  `orbit_string_to_int` (now `strtoll`, which saturates instead of being
  undefined), JSON integers (`json: integer out of int64 range`), SQLite
  counts (`sqlite3_column_int64`) and the clocks (`orbit_clock_ns` and
  `orbit_wall_seconds` no longer wrap at 2^31 or 2038). Shifts take a count
  masked to six bits, and `>>` stays arithmetic. Pinned by
  `tests/suite/int_wrap_64.orb` (which replaces `int_wrap_32.orb`) and
  `tests/suite/bitwise_operators.orb`.
- **Division and remainder by zero are a checked trap.** `x / 0` and `x % 0`
  with a divisor that is only known at run time, and `INT_MIN / -1` and
  `INT_MIN % -1`, used to be undefined C (SIGFPE, exit 136, nothing on either
  stream). They now print `orbit: division by zero at <file>:<line>` or
  `orbit: integer overflow in division at <file>:<line>` to stderr and exit 2,
  the status of an out-of-range list index. A constant divisor other than `0`
  and `-1` is emitted as the bare operator and costs nothing. Float division
  keeps IEEE semantics. The IR carries the line as `line` on `div` and `mod`
  and the file as the module's `sourceName`
  ([IR spec 1.5](IR_SPEC.md#15-checked-div-and-mod)). Pinned by
  `tests/suite/division_by_zero.orb`, `remainder_by_zero.orb`,
  `division_int_min_overflow.orb`, `remainder_int_min_overflow.orb` and the
  control `division_checked_values.orb`.
- **An object field read is lowered from the read's declared type.** The getter
  for `o.field` was chosen by scanning the setters in the function the read is
  in (`objectFieldGetter`), so an object built in *another* function
  (`val o = make(); val c: int = o.count`) and a key no literal ever wrote both
  fell back to `orbit_object_get_raw`, which hands back the field's
  `const char*`: a float read came back as its pointer bits and the program
  answered the wrong value while `orbit check` was clean. The builder now
  records the declared type's kind on the read's own instruction
  (`IRInstruction.fieldKind`, alongside `elemKind`) and the backend consults it
  **only when the setter scan answers raw**, so every read the scan already
  pinned keeps its getter and `tests/suite/object_literals.orb` emits
  byte-identical C. Pinned by `tests/suite/object_literal_cross_function.orb`
  and `object_literal_missing_key.orb`; the residuals (an undeclared
  cross-function read, a chained `o.deep.x`) are recorded in
  [Known Limitations](KNOWN_LIMITATIONS.md).
- **A `port` declaration names the port the server binds.** The checker now
  validates the value - an integer literal 1..65535, anything else is the
  new E1008 - and the emitted server binds it; `argv[1]` still overrides at
  run time. Before, the declaration passed `orbit check` with any value at
  all (`port "8080"`, `port 0`, `port nonexistent_fn()`) and the server
  bound 3000 regardless. `orbit start` and `orbit dev` report the declared
  port, and the emitted C is byte-identical for programs that declare none.
  Pinned by `tests/negative/n81`-`n83`, `tests/suite/port_declaration.orb`,
  and a live declared-port plus argv-override probe in
  `scripts/kynx_gate.py`, which is red on the compiler before this change.
- **Bitwise and shift operators**: `&`, `|`, `^`, `<<`, `>>` and `~`, the
  last gap in the arithmetic. Int-only, like the checker says: a non-int
  operand is the uncoded `Semantic error:` `bitwise '&' takes two ints, not
  'string' and 'string'` (pinned by `tests/negative/n79` and `n80`). Values
  were 32-bit two's-complement when written and are 64-bit since `int` is
  (`~0` is `-1`, `-8 >> 1` is `-4`), shift counts are masked to six bits
  (`1 << 65` is `2`, never C's undefined shift), and the precedence is C's grouping (`&` binds looser than `==`,
  so the suite test writes `(12 & 10) != 8` with the parens it needs). `&`
  stays the pointer sigil in type position and `>>` still closes
  `list<list<int>>`; `orbit fmt` tells the two spellings of `&` apart the
  way it already did for unary minus. Pinned by
  `tests/suite/bitwise_operators.orb`, documented under
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#bitwise-and-shift-operators).
  The constant folder does not fold the new operators yet. The quarantined
  `std/sys/bytes/bitwise.orb` has since returned (2026-10-18): the operators
  were the missing feature, so what was left was a syntax slip and a test,
  and `tests/std/test_bitwise.orb` now covers the same vectors.
- **Object literals**: `return ok { status: "UP", uptime_seconds: ... }`. A
  real value, not a JSON string builder: read a field off it, nest one in
  another, pass it to a function. Backed by a new `OrbitObject` in
  `runtime/json.c` - an insertion-ordered record carrying its own type tag -
  because a generated struct per literal could not be named in a signature and
  its field lookups would collide with the module-wide model field table.
  Key order is source order, so response bodies and the parity goldens stay
  deterministic, and every string inside is escaped on the way out. Fields may
  be string, int, float, bool or object; a list or map is a compile error
  rather than a stored pointer. Pinned by `tests/suite/object_literals.orb`.
  Not yet: reading a field of an object a function returned, and reading back a
  dashed quoted key.
- **Integer literals**: `0x` hexadecimal (`0xFF`, `0xff`, `0xAbCdEf`) and `_` as a
  digit separator (`1_000_000`). Neither existed: `0xFF` lexed as the integer
  `0` with `xFF` dropped, and `1_000_000` lexed as `1`. Both compiled clean, ran,
  and printed a plausible wrong number, which is the worst failure mode there
  is — a bitmask or a port constant that is silently not the one written.
  Pinned by `tests/suite/integer_literals.orb`.
- A `${...}` hole can hold a string literal again (`${show("}")}`). An ordinary
  string scan stopped at the first quote it met, so the literal ended inside the
  hole; the scanner now steps over the hole while looking for the closing quote.
- A model in a `${...}` hole is now a compile error naming the model. A call
  whose callee names a model is that model's construction and had the type
  `unknown`, which is interpolatable, so `${m}` printed as nothing at all.
- A `model` with a field named `a` failed to build: the generated constructor
  was `orbit_model_M_create(OrbitArena* a, orbit_int a)`, so the arena parameter
  and the field parameter collided. The parameter is now `arena_`.
- The constant folder no longer folds a function that branches or calls
  anything. With integer literals now reaching it as values rather than as
  text, it started evaluating `fact` by walking its instructions and returned
  5 for `fact(5)`. Only straight-line pure bodies fold, which is provably
  sound.
- **String interpolation**: `${…}` inside a string, ordinary or triple-quoted,
  is substituted. Together with raw strings this is what lets a JSON body carry
  real values without escaping: `ok 200 """{"count":${n}}"""`. A hole may hold a
  string, int, float or bool; a model, list, map or `result` is a compile error
  rather than a guess. Braces nest and quotes are tracked, so `${ok("}")}` is
  not read as a hole that ended early. Pinned by
  `tests/suite/interpolation.orb`, documented under
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#interpolation).
- `TokType.InterpStringLiteral` was already in the token enum with no producer
  and no consumer, so `${...}` was documented but never built. It is built now.
- `LANGUAGE_REFERENCE.md` claimed object literals (`{ name: "api" }`) and
  field access (`${service.name}`) worked. Neither has ever compiled; the
  section now says so and points at models and raw strings instead.
- `"text: " + 1.5` produced C that the C compiler rejected: a pass that
  propagates `float` through arithmetic also claimed the destination of an
  `add`, and `add` is also string concatenation. A float no longer spreads
  through a concatenation.
- **Raw string literals**, triple-quoted like Python: `"""{"status":"ok"}"""`.
  No escapes are processed, so a JSON body no longer needs every quote doubled
  and a multi-line body can be written the way it is served. The first `"""`
  closes the literal, so a single quote inside is ordinary content; the only
  thing that cannot appear inside is a literal `"""`. Documented in
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#strings), pinned by
  `tests/suite/raw_string_literals.orb`.
- `orbit fmt` no longer aborts on a directory, and a C keyword used as a
  function name (`fn inline()`) now compiles: the call site spells the renamed
  symbol the definition uses.
- **A `result` can be bound to a `val` and passed as an argument.** `result` is
  a struct in C and the register machinery carries values as `uintptr_t`, so a
  local holding one was hoisted as that integer slot and the store became the C
  error `aggregate value used where an integer was expected` - `orbit check`
  passed and only the C step failed. Every call the frontend type table does not
  know, which is every call to a user function, was treated as untypable, and
  that verdict discarded the register type the builder had already taken from
  the callee's return type. The type now stands. Pinned by
  `tests/suite/result_binding.orb`.
- A response body the compiler cannot type no longer reaches C as a bare
  register. `ok 200 1 + true` satisfies `checkCompatibility("string",
  "unknown")`, and `orbit_response_json` then took an `orbit_int` where a
  `const char*` belongs: `check` passed, `build` succeeded, and the first
  request segfaulted. A body the backend has settled on as a scalar is now
  converted with the runtime helper for that type, the same one an interpolated
  value uses. A body it has settled on as a string, a pointer, or still unknown
  is passed untouched, so nothing that already worked changed. Pinned by the
  `response_body_unknown_type` probe in `scripts/werror_gate.py`, which the
  pre-fix output fails on `-Werror=int-conversion`.
- A missing C toolchain is no longer confused with a C compiler that rejected
  our output. The test for "the compiler is not installed" was a substring
  search for `not found` over the compiler's own diagnostics, and clang reports
  a missing include as `'socket_compat.h' file not found` - so a build outside
  the repository, where the runtime include path does not resolve, was told to
  set `ORBIT_CC` for a compiler that was installed and working. The wording is
  now matched together with the compiler's own name on the same line, which is
  what a shell prints and no compiler diagnostic does. The genuine case is
  unaffected, wrappers and all. Pinned by `cc-include-failure-is-not-a-missing-
  toolchain` and `cc-absent-names-the-toolchain` in `scripts/cli_probe.py`.

Runtime and generated code:

- **Runtime security.** `Model.where` and `Model.count` bind every parameter
  with `sqlite3_bind_text` and refuse a condition that holds a quote, `;`, a
  comment, a named placeholder, a second statement or a read outside the
  model's table (`docs/LANGUAGE_REFERENCE.md`, "Filter conditions").
  `orbit_ct_equal` replaces `orbit_streq` and compares JWT signatures and roles
  in constant time. The HTTP parser caps the request line (8192, 414), header
  bytes (65536) and count (100) (431) and `Content-Length` (1 MiB, 413) before it
  allocates, and answers a malformed or conflicting `Content-Length` with 400;
  `ORBIT_HTTP_MAX_*` move the caps. `orbit_alloc_try` no longer hands back a
  block for a size that wraps the cursor, a list capacity whose bytes wrap is an
  error, and a trusted-proxy entry with a non-numeric prefix trusts nothing.
- **`orbit build` drops functions no entry point reaches.** An import put every
  library function into the C. `compiler/ir/prune.orb` now keeps what `main`, a
  route or an extern reaches. `examples/std_crypto_demo.orb` emits 108 229 ->
  55 756 bytes of C with 32 functions dropped. `build --verbose` prints
  `prune: N unreachable functions dropped`; `--emit-ir` runs before the pass.
  See [Architecture](ARCHITECTURE.md).
- **`orbit build` links the prebuilt runtime archive by default.** The C step
  recompiled the whole runtime unity on every build unless
  `ORBIT_LINK_RUNTIME=1` was set. It now links `libruntime_net.a` when the
  program needs no database and the archive sits beside the runtime directory
  (`lib/` or `.orbit/lib/`) with a `.stamp` that matches the runtime sources;
  otherwise it builds the unity as before, without a message.
  `examples/hello.orb`: 3.4 s to 1.3 s (best of 3, gcc 16.2.0, `ORBIT_CCACHE=0`).
  `ORBIT_LINK_RUNTIME=0` forces the unity build, `=1` forces the link for programs
  without a database and fails on a missing archive, and `ORBIT_RUNTIME_LIB` names the archive.
  `scripts/mklib_runtime.py` writes the stamp, and `scripts/dev.py` and
  `_common.disposable_test_env` default the variable to `0` so no gate changes
  what it builds; `make all` sets `1` for the `suite` and `suite_std` gates. See [Architecture](ARCHITECTURE.md#linking-the-runtime).
- **The Windows wizard and the Linux bundle ship the runtime archive.** The
  release workflow builds `lib/libruntime_net.a` and its `.stamp` with
  `scripts/mklib_runtime.py --cc gcc` from the tagged checkout and places `lib/`
  beside `runtime/` in `Orbit-Setup-<version>.exe` and in
  `orbit-linux-x86_64.tar.gz`, so an installed compiler takes the archive link
  above. The stamp holds the digests of the shipped `runtime/` sources. An
  install without `lib/` builds the unity as before. The Linux job builds
  `examples/hello.orb` from the extracted bundle and requires
  `libruntime_net.a` in the `--verbose` output. On a layout with the wizard's
  files, `orbit build` of `hello.orb` from an unrelated directory took 1.2 s
  linked and 3.0 s after `lib/` was deleted (gcc 16.2.0). The bare binary and
  `scripts/install.*` place no `runtime/`, so they stay on the unity build.
- **User builds are compiled at `-O1`, and `orbit build --release` selects
  `-O2`.** `orbit build` shipped `cc -s -O0`, so every user program and the
  runtime it links ran unoptimized; the flag was never revisited after codegen
  worked. `-O1` is the measured knee: on the scratch service's CPU-bound routes
  (`w1d_busy.orb`, 4 keep-alive connections, 120 requests per route, 5
  alternating runs per level) p50 goes 49.18 -> 15.15 ms on `/int` and
  97.62 -> 13.35 ms on `/list` (3.25x / 7.31x), for +1.9 s of build wall time
  (`examples/hello.orb` 2.36 -> 4.29 s). `-O1` to `-O2` is inside the run spread
  on both routes while costing a further +2.5 s, so `-O2` is opt-in and the
  `-O2` strict-aliasing surface on generated C stays off by default. The
  emitted C is byte-identical at every level (the level is a `cc` flag only),
  so nothing under `tests/parity` moves, and `ORBIT_CCFLAGS_EXTRA` is still
  appended last so it still overrides the level. The bootstrap is untouched:
  `build_selfhost.py` and `verify_seed.py` pinned `-O0` in `SUPPRESS_FLAGS` (since 2026-10-26: `-O1`, `-O0` under `--low-mem`). The
  new default exposed one latent test defect, fixed in the same landing:
  `tests/std/time_ns`'s pure arithmetic loop was folded away by gcc at `-O1`
  and `-O2` (exit 6); its workload now writes through a real list, an effect the
  optimiser cannot see past.
- **The per-request access log is buffered.** The emitted log path paid a
  `fflush(stdout)` per line - a `WriteFile` syscall with the msvcrt FILE lock
  held across it, contended by the eight workers - plus two `getenv` calls
  per request in `orbit_color_enabled`. The probe is memoized (the
  environment cannot change under a running server) and the worker loop
  flushes once per pass under `#if ORBIT_LOGS_ACTIVE`. Measured on
  `examples/health_service.orb` (60 000 requests at 16 conns unpaced,
  before/after x logs on/off, 6 windows per arm): log cost 113 421 -> 50 555
  cycles in-handler (~31.5 -> 14.0 us per logged request, 55 % recovered);
  whole-process CPU 29.5 -> 25.4 us per request. Emitted log bytes are
  identical; a hard crash can lose at most the lines of the last pass. The
  remaining half is the line's own construction, dominated by the `printf`
  format walk.

Content and docs track; no compiler changes:

- Language tour, tutorials (blog API, file server, deploy,
  troubleshooting), and the migrations guide.
- FAQ, known-limitations page, release notes, site copy pack.
- `orbit_full_expansion.orb` rewritten in supported 0.1.0
  syntax (the old file used unparsed planned syntax).
- New runnable examples: `blog_api.orb`, `file_server.orb`.
- Removed 7 unimportable std stubs/shadows (`list`, `map`,
  `terminal`, `FileStream`, `Shimmer`, `Env`, `HttpParser`):
  duplicates of builtins, hardcoded fakes, or unparseable as
  written. Survivors documented under the Wave 0 std contract.
- Honesty notes on `sqlite_notes.orb` (bearer routes,
  `:id` routes, writes) and `catalog_service.orb` (writes).
- ARENA.md and ARCHITECTURE.md now describe the memory system the code
  actually has. Both presented `runtime/arena_pool.c`'s 16-arena pool as the
  mechanism serving requests; the generated server uses it only for startup
  scratch work (`compiler/emit/route_runtime.orb:566`, `:585-587`) while each worker
  owns a private 128 KB arena (`:368-369`), resets it per request (`:485`) and
  destroys it at loop end (`:521`). ARENA.md also described string interning as
  FNV-1a hash lookups over `OrbitStringNode` buckets; `runtime/string_pool.c`
  has neither - it is a flat array scanned with `memcmp` ("Lookups are O(n)
  over the pool") - and the FNV-1a plus open addressing in this runtime belongs
  to `Map<K,V>` (`runtime/collections.c`). The same edit records what the
  Arena Oracle was at that date: its O(1) TLS fast path was in `runtime/arena.c`,
  but nothing in the generated server opens or closes a session and no C test
  exercises it.

Known limitations:

- **A `try` binding annotation is not checked, and the probe says so.** `compiler/front/sema.orb:4799` answers `unknown` for a `try`, and `:1146` and `:2012` accept `unknown` against anything, so `val n: int = try decode("x") catch { return 7 }` checks clean when `decode` carries a `string`. `docs/KNOWN_LIMITATIONS.md` records the probe, the three lines, and the count of bare `-> result` declarations -- 51 in 31 files -- which is the same spelling the frontend's 51 `try` give-ups are reading for. Closing it is a checker decision, not a rule this pass can take alone.

## 0.1.0-rc.2 cycle (September 2026)

Developer commands and runtime hardening:

- `orbit run`, `orbit check`, `--help`/`--version` (`feat(dx)`).
- Token-based `orbit fmt` with check mode.
- `orbit doctor`: read-only project checks (D001–D008) with
  optional whitespace fixes.
- Single-host `orbit cluster` v1: up, status, drain, rolling
  restart, down, logs.
- Real `system.*` telemetry builtins (uptime, pid, workers,
  request totals, mean latency).
- Automatic per-route cost ledger (`/_ledger`, `/_ledger/data`).
- Graceful shutdown with drain; honest startup errors.
- Server output flushing so file logs stay live.
- Result `try` propagation and `catch` handlers.
- Docs: brand-voice pass, roadmap and operating guides.

## August 2026 - stabilization

- Behavior suite grown to 13+ programs; suite gate blocking
  in CI again.
- Kynx 0.1: real identity admission, honest Bloom filter
  (negative cache, never authority).
- Runtime fixes: slowloris timeouts, exec opt-in, seed
  credential removed, chunked-encoding 501, strict
  single-placeholder queries, SQL identifier whitelist.
- Parser: nesting limit (E0130), guaranteed forward progress.
- Bootstrap from the committed canonical C as the only path; the
  alternate seed tree removed; runtime moved to top-level `runtime/`.
- 25-probe parity battery versioned; self-host stability
  gate; fixed-point verification; release workflow for the
  fixed-point compiler (Windows + Linux).
- Sovereignty runbook and disaster-recovery docs.

## July 2026 and earlier - bootstrap

- Self-hosted compiler pipeline (lexer → parser → sema →
  IR → C backend) reaching fixed-point convergence.
- C bootstrap amalgamation and seed verification.
- HTTP runtime, arena allocation, SQLite integration,
  JWT/crypto groundwork.
- `orbit fmt`, `orbit doctor`, and an `orbit init` sketch (later removed;
  0.1.0 has no `init` subcommand) first
  implementations; VS Code extension and syntax grammar.
- Native x86-64 backend experiments (lowering, encoder,
  register allocation) - still experimental.
- Repository, CI, installer, and docs foundations
  (CHANGELOG, CONTRIBUTING, status, phases).

## Tags

- `v0.1.0-rc.2`, `v0.1.0-rc.1`, `v0.1-rc.2` - release
  candidates.
- `legacy-seed` - the retired alternate seed lineage,
  historical only.
