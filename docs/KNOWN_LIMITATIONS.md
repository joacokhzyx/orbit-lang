# Known Limitations (0.1.0)

This is the honest list. I keep it next to the docs that use these
features so you don't discover them at midnight. Each entry says
what happens today, how to work around it, and what would change it.
Nothing here is a roadmap promise with a date - it's what I measured
on this build.

Verified on: `orbit 0.1.0-rc.2` (fixed-point build, gcc 13.3.0),
Windows x86-64 and Linux x86-64, September 2026. Linux paths are
marked UNTESTED below where I couldn't run them.

**Start with the first section.** Everything below that one is a feature
gap you can design around. The first section is nineteen programs where
`orbit check` reports no errors and the answer you get back is wrong, and
it is the one that will cost you an afternoon.

## Nineteen programs the compiler should reject and does not

Nothing in this section is a design decision or a missing feature. Each
entry is a program that fails to compile in a language with a type
system, compiles here, and computes something else.

The list is not written from memory. It is the output of one command
against the fixed-point compiler, and the same command is a CI gate, so
it cannot rot:

```console
$ python scripts/negative_gate.py --compiler <orbit>
...
Finished negative: 34/34 pass (19 known defects still accepted)
```

Every entry is a file in `tests/negative/` whose header names the defect
class. A program the compiler wrongly accepts declares `known-defect:`
and the gate asserts the bug is **still there** - so when one gets fixed
the gate goes red and asks to be re-declared. That is what makes each
entry traceable to a `file:line` you can go and read.

Every value quoted here was measured by running the program against the
fixed-point compiler built from the committed canonical C, SHA-256
`91e6f79…` (`python scripts/build_selfhost.py --cc gcc`). Numbers that
move per run - an address, a pointer - are given as the run I made, with
the reason they are not pinned. Line numbers into `compiler/` name the
function rather than the row, because the compiler moves under the
docs; a `tests/negative/` filename and a `FINDINGS` ID do not.

**Two of the nineteen are already fixed in the tree and not yet in a
release.** Signed division (`n28` below) was fixed in `672151c`, and the
32-bit range check on an integer literal (`n29`) is fixed in the working
tree — the ratchet noticed, which is what it is for:

```console
Failed tests/negative/n29_int_literal_out_of_range.orb: known defect F-0014
looks FIXED: orbit check now rejects it with 'Semantic error: Integer
literal out of range for int: 2147483648 does not fit in 2147483647;
orbit_int is a 32-bit int'
```

A red line that names the fix and asks you to re-declare the case is the
gate working. Both land when the canonical is promoted; until then the
released compiler still has them, which is why the nineteen is the
number here.

Two groups, and the split is the whole point.

### The silent group: no error anywhere, a wrong value

These are the ones that cost you. There is no diagnostic, no C error, no
exit code to trip over. You find them in a log.

**1. `.at()` on a list answers 0.** The most ordinary list program there
is:

```orbit
val s = ["alpha", "beta", "gamma"]
print(s.at(1))          // 0. It should be beta.
```

`.at()` is classified as a *string* access and compiles to
`orbit_string_at` on a list pointer, so it reads a byte at an offset into
the `OrbitList` struct. On a list of ints the same call is worse, because
what comes back is a byte of the list's `data` pointer:

```orbit
val n = [10, 20, 30]
print(n.at(1))          // 0. It should be 20.
print(n.at(0))          // 48 on this build, 96 in a program that allocated
                        // one more string first. The pointer's low bytes.
```

`orbit check` is clean for all of it, and `s.len()` is still right (3), so
nothing else in your program notices. **Use `.get(i)`, which is
bounds-checked and does the right thing.** Pinned as
`tests/negative/n31_at_on_list_of_strings.orb` and
`n10_at_on_list_of_int.orb`, both with the wrong value in the header
because it is stable.

**2. A call argument's type is never checked against the parameter.**

```orbit
fn takesInt(x: int) -> int { return x + 1 }
print(takesInt("a string"))   // 1092635112 on this run
```

The front end knows the parameter type and the argument type and checks
neither, so the string's heap address arrives in an `int` register and the
program prints it. I got a different number on every run, which is the
point: it is an address, not a value. Nothing is pinned about the number;
what the case pins is that the call is still accepted. This is the shape
that propagates - an int where a string was meant is a garbage number, not
a crash. Pinned as
`tests/negative/n33_call_argument_type_unchecked.orb`.

**3. An undeclared identifier prints a stack address.**

```orbit
print(undeclaredThing)   // 99524317737632 on this run
```

A typo in a name, or a name you meant to import, produces no error. The
register is simply whatever the stack held. Pinned as
`tests/negative/n09_undeclared_identifier.orb`.

**4. A call with the wrong number of arguments drops the extra ones.**

```orbit
fn add(a: int, b: int) -> int { return a + b }
print(add(1, 2, 3))      // 3
```

It compiles, it runs, and it silently computes a different function call
than you wrote. Pinned as `tests/negative/n04_call_wrong_arity.orb`.

**5. A model constructor accepts the wrong argument types.**

```orbit
model Point { x: int  y: int }
val p = Point("a", true)
print(p.x)               // 203344359
```

Same mechanism as #2, on the constructor. Pinned as
`tests/negative/n14_model_ctor_wrong_types.orb`.

**6. An exponent literal is silently truncated.**

```orbit
val v = 1e2
print(v)                 // 1. It should be 100.
```

The lexer has no exponent branch at all, so `1e2` is the integer `1`
followed by an identifier `e2` that nothing declares and nothing reads.
The identifier is dropped without a word. Pinned as
`tests/negative/n26_exponent_literal_truncated.orb`.

**7. `/` and `%` disagree with `+`, `-` and `*` about a negative
operand.** *Fixed in `672151c`, not yet in a release.*

```orbit
print((0 - 7) / 2)       // -4. It should be -3.
print((0 - 7) % 2)       //  1. It should be -1.
print((0 - 7) / 3)       // 1431655763. It should be -2.
print((0 - 7) % 10)      //  9. It should be -7.
```

Integer `/` and `%` are emitted with **both** operands cast to
`uintptr_t` - the `div` and `rem` arms of the emitter in
`compiler/c_backend.orb` - so a negative dividend is divided as a 64-bit
unsigned number and only the low 32 bits survive. `+`, `-` and `*` carry
the same cast and do not show it, because unsigned wraparound and signed
overflow agree mod 2^32.

`1431655763` is the one to remember: a billion is not a plausible answer to
a division of small numbers, so it does not look like a bug at all.

**The parentheses matter.** `0-7 / 2` is *not* this bug - it parses as
`0 - (7/2)`, computes correctly, and prints `-3`. The unparenthesised form
is a different program that looks identical, and both appear in real code.
Pinned as `tests/negative/n28_negative_operand_division.orb`.

**8. An integer literal out of range is a different number, not an
error.** *Fixed in the working tree, not yet in a release.*

```orbit
print(2147483648)        // -2147483648
print(4294967296)        // 0
```

`parseIntSelfhost` in `compiler/builder.orb` folds
`result * base + digit` into an `int` and never asks whether the literal
fit. A literal is not a runtime value, so there is no later point at
which this can be caught. gcc rejects `2147483648` for the same reason
("integer constant is so large that it is unsigned"); Python and C#
reject it outright. Pinned as
`tests/negative/n29_int_literal_out_of_range.orb`.

**9. An index past the end of a string is 0, which is a real character.**

```orbit
val s = "hello"
print(s.at(99))          // 0. It should be an error.
print(s.at(1))           // 101 - correct, which is what makes it hard to see
```

`orbit_string_at` (`runtime/collections.c:369-373`) answers 0 for
`index >= len`, and 0 is also the byte value of NUL. The front end has
both the receiver and the index and raises nothing. Pinned as
`tests/negative/n32_at_out_of_range.orb`.

**10. An annotation naming a type that does not exist is accepted and
ignored.**

```orbit
val v: widget = 3
print(v)                 // 3
```

Completely silent: check clean, builds, runs, and gives the right answer
*by accident*. This one is on the list because it is the mechanism behind
most of the others, not because it miscompiles today. Pinned as
`tests/negative/n11_unknown_type_annotation.orb`.

### The loud group: `orbit check` accepts it, the C step refuses, and the error names a C type

These fail, which is a real difference - but the diagnostic points at a C
symbol or a C struct member rather than at your Orbit source, so you get
`<build>:84:31: error` with a line number in generated C. You can work
with it. You cannot act on it from the message.

| program | what the C step says | pinned as |
|---|---|---|
| `val n: Int = 1` then `print(n)` | `unknown type name 'Int'; did you mean 'int'?` | `n30_capitalised_type_annotation.orb` |
| `val v = 2.5E3` | `unknown type name 'E3'` | `n27_exponent_capitalised_type.orb` |
| `m.nonexistent` on a `Point` | `'OrbitModel' has no member named 'nonexistent'` | `n05_model_missing_field.orb` |
| `s.radius` on a `Square` variant | `'OrbitModel' has no member named 'radius'` | `n15_union_variant_missing_payload.orb` |
| `n.nothing` where `n` is `5` | the same, plus `warning: cast to pointer from integer of different size` | `n06_field_on_int.orb` |
| `n()` where `n` is `5` | `called object 'n' is not a function or function pointer` | `n12_call_non_function.orb` |
| `Point(1)` for a two-field model | `too few arguments to function 'orbit_model_Point_create'` | `n13_model_ctor_wrong_arity.orb` |
| calling a name nothing declares | `implicit declaration of function '…'`, then a link error | `n22_undeclared_function_call.orb` |

Three of these deserve a note.

**A capitalised type name only fails if the binding is read.** Delete the
`print` and `val n: Int = 1` builds and runs, because an unused local is
never declared in the generated C, so the invented type is never written
down. That is why this reads as "works" in a test and breaks in an
application.

**`2.5E3` is the same lexer gap as `1e2`, one letter apart, and it fails
the other way.** The register really does hold 2.5; the identifier `E3` is
capitalised, so `mapTypeToC` (`compiler/c_backend.orb:264`) answers `E3*`
and writes that C type into the output. Lower case (`2.5e3`) is the
silent half and prints 2. The case of the letter is the whole mechanism,
which is why both halves have to be fixed together.

**The undeclared-function case depends on luck.** `orbit check` is clean
either way; what happens next depends on whether the runtime happens to
define that exact name. I measured `orbit_int_to_string_selfhost(1)`
building and printing `1`, because `runtime/selfhost.c:122` defines that
symbol. A name nothing defines gets a C error instead. So the same class
of mistake is silent or loud depending on a name you did not choose.

### Why the list is nineteen and not a coincidence

Because most of it is one root cause, and the root cause is measurable.
`scripts/unknown_census.py` counts how much of the corpus the front end
types at all, over 97 files and 37,628 instructions on this build:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 11,480 | **30.5%** |
| ...with no diagnostic at all | 5,332 | **46.4% of the unknown** |
| ...of those, opcode `call` | 2,904 | |
| ...of those, opcode `member` | 2,428 | |

Read that as a user rather than as a compiler person. Almost a third of
every value the compiler handles has no type, and almost half of *those*
- 5,332 instructions - reach codegen without the front end knowing it has
failed. The two opcodes it is blind on are `call` and `member`: a function
call and a field read. Those are the two operations that produce a
**wrong answer** rather than a failure, which is exactly the silent group
above. E2001/E2002/E2003 account for the rest to the unit - their counts
equal the unknown `load` / binary / unary counts exactly - so 5,332 is
measured, not estimated.

The nineteen fall into two piles, and the boundary is a judgement call I
will show you rather than ask you to trust.

**Pile A, eleven: the type was never resolved, so there was nothing for a
rule to check against.** A field read, a call, or a member access on a
binding with no annotation, or on a name that does not exist at all:
`n05`, `n06`, `n09`, `n10`, `n11`, `n12`, `n15`, `n22`, `n27`, `n30`,
`n31`. These are not eleven unrelated bugs. They are one thing seen at
eleven different call sites, and the single line that lets an untyped
value walk past every type rule the language has is the first statement
of `checkCompatibility`:

```orbit
fn checkCompatibility(expected: string, actual: string) -> bool {
    if expected == "unknown" || actual == "unknown" { return true }
```

`compiler/sema.orb:326`. **`check` on one side and `unknown` on the other
is a pass**, which is the correct thing to do for a value the compiler
genuinely cannot type yet, and it is also the reason a whole class of
mistakes is invisible. The sharpest instance is entry 2: `takesInt` is
declared `fn takesInt(x: int)`, the argument is a string literal, and the
call is accepted - so the argument's side of the comparison is reaching
that line as `unknown`.

**That is the one change that would shrink this list most.** Make
`unknown` stop being a pass - resolve names so the type is written down,
and stop treating its absence as consent - and the type rules the
language already has start firing on the majority of the list.

**Pile B, eight: the front end has every type it needs and the check is
simply not written.** Arity, twice (`n04` a function, `n13` a model
constructor); a model constructor given the wrong argument types (`n14`);
the missing exponent branch (`n26`); a 32-bit range check on a folded
literal (`n29`, fixed in tree); the signedness of `/` and `%` in the
emitter (`n28`, fixed in `672151c`); and a bounds check in
`orbit_string_at` (`runtime/collections.c:369-373`, `n32`). Eight narrow
fixes in five files - `sema.orb`, `builder.orb`, `lexer.orb`,
`c_backend.orb`, `runtime/collections.c` - each one to three lines in a
different place. Two of the eight have landed since this was written,
which is the shape the rest of the work will take.

That asymmetry is the argument for doing the type work first: this is
nineteen defects, and it is **one mechanism plus eight small fixes**, not
nineteen fixes. Pile B is cheap and worth doing regardless; pile A is what
makes the language trustworthy, and it is the bigger half.

Run `python scripts/unknown_census.py --compiler <orbit> --json` for the
per-file breakdown, and see
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag)
for the mechanism underneath.

## Writes work; duplicates and missing tables fail honestly

`Model.create()` stores the row and returns `true`. It returns
`false` when the `id` already exists (PRIMARY KEY) or the JSON
payload has no usable fields. `Model.delete()` returns `true` only
when a row was actually removed. Verified live with literal JSON
and `req.body()` input, including round-trip reads
(`examples/posts_crud.orb`).

## Auth helpers work against the sessions table

`req.bearer_token()` extracts the token (never crashes on missing
headers), `req.has_role("admin")` and `req.role()` resolve through
`sessions` joined to `users.role_name`, with `expires_at` honored
(`0` means never). Verified live on `examples/sqlite_notes.orb`:
401 without token, 403 for non-admin deletes, 200 for admin.
Using any auth helper links the database automatically; tokens
themselves are rows you insert (see `tests/auth/auth_harness.c`).

## Path parameters match, values are raw

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Two limits
remain: captured values are not percent-decoded, and at most 8
captures bind per request. Query values (`?id=`) keep working
alongside.

## Custom tables are created, not migrated

On startup the runtime creates the four built-in tables (`notes`,
`products`, `users`, `sessions`, plus demo seeds) and one table
per model in your program (`CREATE TABLE IF NOT EXISTS` from the
model fields: `string`→`TEXT`, `int`/`bool`→`INTEGER`,
`float`→`REAL`, an `id` field becomes the primary key). There is
still no migration story: adding a field later does not alter an
existing table (see `docs/guides/migrations.md`).

## Multipart uploads aren't implemented

`req.file()` compiles but maps to a stub that returns a
placeholder path and saves nothing (called with one argument it
also triggers a C arity warning). There is no multipart parsing
and no disk persistence in 0.1.0. The file-server tutorial
(`docs/tutorials/file-server.md`) uploads raw bodies and says so.

## Cluster is single-host only

`orbit cluster` starts N copies of one service on this machine.
There is no shared state, no proxying, no failover, and no
multi-host story. `up`, `status`, and `down` are verified in the
deploy tutorial; `drain` and rolling restart follow the platform
rule below.

## No joules on Windows

Energy is reported in joules only where sensors exist (Linux
RAPL). On Windows the honest proxy is CPU time plus memory -
never converted to joules with a universal factor. The measurement
record in [Resource and Energy Measurement](ENERGY.md) enforces this.

## No p50/p99 yet

`system.*` exposes uptime, pid, worker count, total requests, and
mean latency in microseconds. There is no latency distribution
(no p50/p95/p99) and no success/error split. `/_ledger` adds
per-route request counts, mean milliseconds, and DB share. What
isn't measured isn't exposed.

## Windows drain is kill

Graceful shutdown (drain in-flight requests, then exit) runs on
POSIX through SIGTERM. On Windows the stop is `TerminateProcess`:
immediate, with in-flight requests lost. `drain` and the graceful
phase of `restart`/`down` are best-effort stops there.

## Two servers, one port: no error on Windows

Starting two servers on the same port on Windows doesn't fail
loudly in my test - both processes kept running and the port
answered. Don't rely on a bind error to catch the mistake; check
with `netstat -ano | findstr <port>` and stop the older process.
UNTESTED on Linux.

## An object literal cannot be a `-> model` return type

`inferType` returns the literal string `"object"` for an object
literal (`compiler/sema.orb:980`), and the return check compares
that name against the declared one. A model name is not `"object"`,
so the comparison fails and you get a mismatch naming a type that
was never in your source:

```orbit
model Point { x: int, y: int }
fn make() -> Point { return { x: 1, y: 2 } }
// Semantic error: Return type mismatch: expected Point, got object
```

The literal itself is fine - the feature landed, and `orbit check`
accepts it as a model field, as a local, and as a `response` body.
Only the `-> model` annotation is unreachable. Workaround: build
the model with its constructor and return that, or return the
literal from a function typed `-> response`. (Reading a value back
out of an object with `.get()` is a separate miscompile - see
"a list slot has no element type" below, and
[LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#maps).)

## A generic model typechecks, then emits C that does not compile

`model Box[T] { v: T }` passes `orbit check` with no errors and then
fails in the C step:

```console
$ orbit build gen.orb -o gen
  <build>:74:5: error: unknown type name 'T'
  <build>:77:63: error: unknown type name 'T'
  <build>:91:29: error: unknown type name 'T'
```

`T` reaches the emitter as an ordinary type name, `mapTypeToC` has
no case for it, and the backend helpfully casts it to `void*` in
register declarations while emitting a bare `T*` in the struct and
the constructor. There is no monomorphisation, so a generic type
parameter is a name with nothing behind it. This is the same root
cause as the quarantined `std/quarantine/option.orb.quarantined`:
`Option<T>` cannot be written until this can.

## `std/` is 13 modules, and 8 of the 20 it used to be are not coming back

**13 modules, 13 of 13 compile and merge into one program.** Verified:
`tests/std/test_imports.orb` imports all thirteen into a single binary and
calls into each, and it passes. `tests/std/` is 17 files and runs
17/17 green, one of them declared `known-failing` so that a fix arrives
as a red run rather than as a silent behaviour change.

`std/` was 20 modules. **Six were deleted, and deleting them was the
honest response**, because each was a function that returned a value and
was not computing it:

| deleted | why it had to go |
|---|---|
| `std/sys/crypto/hash.orb` | `fnv1aHash` was `1469598103 + data.len()`, so `fnv1aHash("hello") == fnv1aHash("hellp")` was **true**. `generateKynxToken("user42")` derived a security token from the *length* of the seed. |
| `std/sys/bytes/buffer.orb` | `appendByte` stored nothing, and `readAt` returned 1/0 and never returned the byte. `writeU16LE`/`writeU32LE` cannot be repaired either: a NUL byte vanishes from a string, measured — `from_char(65) + from_char(0) + from_char(66)` is length 2. `std/bytes/bytes.orb` already owns the honest version. |
| `std/sys/net/socket.orb` | There is no socket API anywhere in the language or the runtime. `bindAddress` returned `true` for a valid port on a socket whose `fd` is 0, i.e. stdin. |
| `std/sys/io/io_threading.orb` | No thread primitive exists in the lexer or the runtime. `createPool` set `is_active: true` and `dispatch` incremented a counter. |
| `std/core/memory.orb` | `alloc` returned a null pointer and `free` was a no-op. |
| `std/core/result.orb` | `result` is already a builtin with `ok`/`err`. An unparseable shadow of a working builtin. |

**Two are quarantined rather than deleted**, as `*.orb.quarantined` in
`std/quarantine/`, and both are files the language cannot read today:

| quarantined | the language feature that does not exist |
|---|---|
| `option.orb.quarantined` | a generic tagged union. `union` has no type parameter list, and a generic `model` typechecks and then emits a C `T` that does not exist. |
| `bitwise.orb.quarantined` | bitwise operators. `^` and `~` are invalid characters in the lexer, `&` and `|` are tokens but not binary operators, `<<` and `>>` lex as two separate tokens. |

They are not `.orb` on purpose: `.orb` is the toolchain's marker for
loadable source, and a file the parser cannot read breaks
`orbit fmt --check std` on every run and can only be `import`ed to
produce a parse error. A quarantined module is not deleted because
deleting loses the only written record that the feature was wanted; the
git history alone does not say *which* feature or *why* it is
impossible. `std/quarantine/README.md` has the convention and the
"what does not belong here" list.

So there is **no `std/json`**, no `std/fs` directory creation, no
`parseFloat`, and no `Option`. Not "not yet documented" — the modules
that claimed them are gone or quarantined, and
[LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#stdquarantine-specified-not-implemented)
names the absences.

## `orbit fmt` splits a negative literal after `return`

`return -1` comes back as `return - 1`:

```console
$ printf 'fn main() -> int {\n    return -1\n}\n' > t.orb
$ orbit fmt t.orb && grep return t.orb
    return - 1
```

It is specific to `return`. `val x = -1`, `print(-1)`, `f(-1)` and
`3 * -1` are all left alone, and so is `return - 1` if you write it
that way already — the formatter is idempotent, it just disagrees
with you about the first pass. It still compiles and still returns
-1, so this is cosmetic. It is listed because the formatter is
treated as authoritative by `fmt --check`, and applying it has
therefore spread `- 1` through 15 sites across 5 files (`std/io/io.orb`,
`std/bytes/bytes.orb`, `std/sys/crypto/jwt.orb`,
`std/collections/lists.orb` and `lib/arena.orb`). Fixing
`compiler/fmt.orb` will need a re-run of `fmt` over those trees.

## A list slot has no element type, so nothing can check it

`OrbitList` is `{ void* data; size_t len, capacity, elem_size; ... }`
(`runtime/types.c:195-201`). One pointer per element, and nothing
records what it points at. This is the single most load-bearing gap
in the language - it is why an unannotated binding is assumed to be
a string, and it is why the `std/collections/lists.orb` helpers
cannot protect you:

| program | result |
|---|---|
| `getOr([1,2,3], 0, "d")` bound to a `string` | **segfault** |
| `indexOfStr([[1,2],[3,4]], "x")` | `-1`, silently |
| `[10,20,30].at(0)` | the low byte of the `data` pointer - 48, 144 and 0 in three programs differing only in what else they allocated |
| an object `{ "a": 1 }`, with `.get("a")` bound to an `int` | segfault |

`orbit check` reports no errors for any row. A method call directly on a
literal does not parse (`Expected ')' after arguments`), so each of these needs
the value bound to a `val` first — which is what I did. Use `.get(i)`, not
`.at(i)`, and treat a list's contents as something only you know.

## 30.5% of instructions are `unknown`, and 46.4% of those are silent

`scripts/unknown_census.py`, run over 97 files and 37,628
instructions on this build:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 11,480 | **30.5%** |
| ...with no diagnostic at all | 5,332 | **46.4% of the unknown** |
| ...of those, opcode `call` | 2,904 | |
| ...of those, opcode `member` | 2,428 | |

The silent half is the honest number. E2001/E2002/E2003 account for
the rest to the unit - their counts equal the unknown `load` /
binary / unary counts exactly - so 5,332 is measured, not
estimated. Those are `call` and `member` expressions: the two
places where the front end does not know it has failed, and the same
name-and-shape classification as the list problem above. This is the
same measurement as the root-cause table in
[nineteen programs the compiler should reject](#nineteen-programs-the-compiler-should-reject-and-does-not),
and it is what the nineteen entries there are made of.

Separately, E3001 "expression cannot be lowered to TIR" fires 4,190
times. That is a whole class of expression the front end gives up
on, and it is not in the unknown total because there is no
instruction to type. Worst file by share: `compiler/parser.orb` at
49.7% (2,146 of 4,316).

Two tools, and the difference matters. `unknown_census.py` is the
**measurement** and never fails anything. `scripts/unknown_ratchet.py`
is the **gate**: it reads the census output, compares two of the
numbers against a committed baseline in `scripts/baselines/`, and
fails if either went *up*. It does not fail because the count is high -
30.5% is the number the type work has to be scoped against, and a
zero-bar gate is a gate everybody deletes. Verified here:

```console
$ python scripts/unknown_ratchet.py --compiler <orbit> --cc gcc
  unknown_instructions          11480  baseline  11480  unchanged
  unknown_without_diagnostic     5332  baseline   5332  unchanged
Finished unknown-count: 11480 (baseline 11480, ratchet holds)
```

Raising a baseline is a deliberate act: `--write-baseline` refuses to
move a number up unless `--allow-regression` is also passed. So the
count can only go down, which turns "do not regress this" from a rule
people follow into a property the build enforces.

## The frontend gate is 6/6

`scripts/frontend_gate.py` runs six fixtures and all six pass. Two of
them - `tests/frontend/syntax_error.orb` and
`tests/frontend/unresolved_type.orb` - **did not** build for most of
this cycle, so their contracts were never checked, and the docs said so.
That is fixed: `compiler/lexer.orb` now imports `compiler/extern.orb`
before calling `orbit_os_write_stderr_selfhost`, and the missing
`parseIntSelfhost` declaration went with it.

```console
$ python scripts/frontend_gate.py --cc gcc --compiler <orbit>
Checking tests/frontend/unresolved_type.orb ... TIR suppressed as required
...
Finished frontend: 6/6 pass
```

Recorded because a gate that was 4/6 and is now 6/6 is exactly the kind
of number that gets copied from an old document. If you are reading a
claim that the frontend gate is incomplete, it is out of date.


## `lib/net.orb` does not build

It type-checks and then the generated C is rejected: the module
declares `extern fn syscall(n, a1, a2, a3)`, which collides with
the real `syscall` in `runtime/socket_compat.h`.

```console
  <build>:121:18: error: conflicting types for 'syscall'
  <build>:121:18: error: static orbit_int syscall(...);   // ours
     41 | #include <sys/syscall.h>                            // glibc's
```

Its event loop is `while running { ... running = false }`. It is a
design sketch and is documented as one; it is not a working wrapper,
and there is no socket API in the language or the runtime.
`docs/ARCHITECTURE.md` says the same.

