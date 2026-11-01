# Known Limitations (0.1.0)

This is the measured list. It sits next to the docs that use these features, so
a limit is found before midnight. Each entry says what happens today, how to
work around it, and what would change it. Nothing here is a roadmap promise
with a date. It is what was measured on this build.

Verified on: `orbit 0.1.0` (fixed-point build; gcc 16.2.0 on Windows x86-64
and gcc 15.2.0 on Linux x86-64), November 2026. Both hosts ran the full gate
sequence. Linux paths are marked UNTESTED below where the run was not
performed.

**Start with the first section.** Everything below that one is a feature
gap you can design around. The first section is about the programs `orbit
check` refuses, which used to be the reason to distrust it: nineteen of them
translated cleanly and computed something else. All of those are diagnostics
now, and the section records what they answer instead. It includes the two
checks that were wrong in the direction of refusing valid code, which is the
failure mode worth reading about.

## Doctor over a whole tree needs more arena than a 4 GB machine offers

`orbit doctor compiler` allocates more than 2.9 GB of arena, and
`orbit doctor .` over this repository (472 files) reaches the same ceiling.
The default is 75% of physical memory, so a 3.9 GB WSL instance aborts with
`arena ceiling reached ... the limit is 2928 MB from ORBIT_ARENA_MAX_MB`.
With `ORBIT_ARENA_MAX_MB=20000` the compiler scan reports 138 findings in
9.6 s; on Windows the repository scan finishes in 23 s under the 6 GB
default, and a 16 GB CI runner's default covers both. The scan typechecks
every file in one arena, so the change that would remove the requirement is
releasing per-file state, not a larger default.

## Doctor skips tool state: dot-directories and what .gitignore names

A directory whose name begins with a dot is not scanned, so `.orbit/` with its
thousands of build copies never is. The scan root's `.gitignore` is read too:
a line that is just `name/` keeps that directory out, which is how `scratch/`,
`dist/` and the fuzz output stay out of a repository-wide run. Nested
`.gitignore` files, wildcards and anchored patterns are not interpreted.

With both rules, `orbit doctor .` over this repository scans 472 files and
reports 439 findings in 23 s on Windows. The 4 GB Linux run still reaches the
arena ceiling on the same scan; that is the section above, not the walk.

## The silent group is empty

This section used to be called *nineteen programs the compiler should reject
and does not*, and it was the reason this document existed. Every entry in it
is now a diagnostic, so it has been replaced rather than kept as a museum.

The reason to write that down rather than just delete the heading is that the
document depended on the list. It is the evidence that `orbit check` is worth
running. One command produced it, and that command is also a CI gate, so it
could not rot quietly:

```console
$ make negative
...
Finished negative: 107/107 pass (0 known defects still accepted)
```

One hundred and seven programs: every one must be rejected and is. The last one
to be fixed was F-0025, the assignment target: a `val` store, a type mismatch
and an undeclared name now produce E1009. Before it,
[a `list` parameter with no element type](#a-list-carries-an-element-type-now-and-the-checker-enforces-it)
was the last, and generic functions gave it a diagnostic. What remains is a
design choice (the bare `list` spelling stays lenient for dynamic values), not
a missing check.

## A shadowed `val` gets its own C variable (fixed)

This one used to compute something other than what you wrote: it typechecked,
it ran, and the answer was wrong. The checker always resolved it correctly --
`v` inside the `if` is a different `val` with its own scope -- but the emitter
declared one C variable per *name*. So both `val v` became a single
`orbit_int v`, and the outer read came back clobbered:

```orbit
fn f(flag: bool) -> int {
    val v = 10
    if flag {
        val v = 20
    }
    return v    // was 20, is 10
}
```

Every declaration now owns a distinct C symbol, minted where the IR value is
created (`defineVariable` in builder.orb). It is the spelling when no live outer
scope declares it, and `name__sN` when one does. It is resolved innermost-first
at every read and write. Without shadowing the symbol IS the spelling, which is
why the canonical barely moved. Pinned by
`tests/suite/scope_shadow_clobbers_outer.orb` (exit 0, including the
parameter-shadowing case).

## Four bugs that typechecked, ran and were wrong

None of these was a missing check. Every one compiled clean, ran, and produced
a wrong answer, which is why no gate found them. A gate runs the program and
compares what it prints, and a program that prints `7.0` instead of `7` prints
something.

They are one class, and the class is worth more than the four entries:

- **A name derived in two places.** A field read was typed from a scan of every
  field *name* in the module, last match winning, instead of from the model that
  owns the field. Two models sharing a field name with different types read each
  other's member.
- **A rule implemented twice.** Checker and emitter each peeled one `list<>` to
  find a generic parameter. The checker peeled to any depth and the emitter to
  one, so the same literal checked as `list<list<float>>` and built as
  `Nested_unknown`.
- **A cast inherited from its neighbours.** The float arm of a constructor
  argument read `(orbit_float)(uintptr_t)(x)`, written to match the int arm
  beside it, where the `uintptr_t` hop is harmless. For a float it truncates, so
  every float model field lost its fraction.
- **An empty string used as "no value".** A parameter not resolved to an
  instance was defined with an empty type name. Empty is not `unknown`: a symbol
  with no type resolves to nothing, and the first field read through it loaded a
  field no declaration named.

The pattern: **wherever the checker and the emitter must agree on a derived
name, that derivation has one implementation and one test that pins it.** Two
implementations is a coin flip that lands wrong at runtime rather than at build
time, which is the only place a coin flip is not allowed to land.

Where the shared derivations live, and why that file exists: `literal.orb` is a
leaf module importing nothing, so `builder.orb`, `sema.orb` and `parser.orb` can
all depend on it and the import graph stays a DAG. It was created for exactly
this reason ([F-0004](ERROR_CODES.md#f-code-index)). A helper in the wrong side of the graph was an unresolved
call, which is not an error: `orbit check` stayed clean and the C compiler
rejected the output with a name it had never been given.

The tests that pin all four are `tests/suite/model_field_owner_typing.orb`,
`generic_nested_argument.orb` and `parameter_type_fallback.orb`.

What replaced the list, in the order the work was done:

| what used to happen | what happens now |
|---|---|
| `.at()` on a list read a byte of the list pointer and answered 0 | `.at()` and `.get()` both do the right thing, on ints and on strings |
| a call argument's type was never compared with the parameter's | [`E1005`](ERROR_CODES.md#e1005--call-argument-type-mismatch), naming the parameter and both types |
| an undeclared identifier printed a stack address | *Undeclared identifier: nothing in scope declares it* |
| a call with the wrong arity dropped the extra arguments | *Wrong number of arguments to f: it takes 1, got 3* |
| a model constructor accepted the wrong argument types | [`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity), naming the field and both types |
| `1e2` was the integer `1`, `0b101` was the integer `0` | both are literal values; an exponent is always a float |
| `(0-7)/2` was `-4` and `(0-7)/3` was `1431655763` | `-3` and `-2`, C semantics, pinned by `div_mod_signed.orb` |
| `9223372036854775808` silently became `-9223372036854775808` | *integer literal does not fit an orbit_int* |
| `s.at(99)` answered 0, which is the NUL byte | [`E1002`](ERROR_CODES.md#e1002--literal-index-out-of-range), naming the index and the length |
| `val v: widget = 3` was ignored | [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch), and a capitalised unknown type is refused too |
| `val n: Int = 1` reached gcc as `Int*` | [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch), with the note that types are lower case or declared |
| `m.nonexistent`, `s.radius`, `n.nothing` died in the C step | [`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity), and the receiver's own members are the only ones |

Two of those deserve a note about *how*, because both were the same mistake
wearing different clothes.

**A check that only knows one table is a check that guesses.** [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch) refuses
a capitalised type name that nothing declares, which is what makes `val n: Int
= 1` a diagnostic. Its first version asked the checker's two type registries,
and those registries do not hold models. `checkModelDecl` fills
`modelFieldOwner` and `TypeDecl` never sees a model, so it also refused
`List`, `Map`, `Result` and `Response`, which are real. Forty-three green
tests did not notice, because nothing in the suite used the capitalised
spelling. `tests/suite/type_spellings.orb` exists so that it cannot happen
again.

**The loud group is now silent too.** The table this section used to carry is
empty. It listed programs that translated cleanly and were rejected by the C
compiler, with an error naming a C symbol or a C struct member instead of the
Orbit source. Those messages reached the user as `orbit build: couldn't finish
the C step - this one is on me, not your code`, which is a sentence about the
compiler's feelings, not about the program. Every one of them is now an
[`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity) with a line and a column in the user's own file.

The mechanism underneath is described in
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag),
and the measurement that says how much of the front end is still untyped is
[below](#291-of-instructions-are-unknown-and-455-of-those-are-silent).


## Writes work, but duplicates and missing tables fail

`Model.create()` stores the row and returns `true`. It returns
`false` when the `id` already exists (PRIMARY KEY) or the JSON
payload has no usable fields. `Model.update(id, json)` writes only the
keys present in the payload (never `id`) and returns `true` only when a
row actually changed. A missing id or a fieldless payload is `false`.
`Model.delete()` returns `true` only
when a row was actually removed. Verified live with literal JSON
and `req.body()` input, including round-trip reads
(`examples/posts_crud.orb`).

## Auth helpers work against the sessions table

`req.bearer_token()` extracts the token and never crashes on missing
headers. `req.has_role("admin")` and `req.role()` resolve through
`sessions` joined to `users.role_name`, with `expires_at` honored
(`0` means never). Verified live on `examples/sqlite_notes.orb`:
401 without token, 403 for non-admin deletes, 200 for admin.
Using any auth helper links the database automatically. Tokens
themselves are rows you insert (see `tests/auth/auth_harness.c`).

## Path parameters match, values are decoded

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Captured
values are percent-decoded by `req.param()`. The capture table belongs to
the request and grows with the pattern, so the count is the route's, not a
fixed slot count. Query values (`?id=`) keep working alongside.

## Custom tables are created, and forward DDL migrates

On startup the runtime creates the four built-in tables (`notes`,
`products`, `users`, `sessions`, plus demo seeds) and one table
per model in your program (`CREATE TABLE IF NOT EXISTS`). The columns
come from the model fields: `string`→`TEXT`, `int`/`bool`→`INTEGER`,
`float`→`REAL`, and an `id` field becomes the primary key. Forward
DDL now runs through `migrations "<SQL>"` lines (each once, in
declaration order, tracked in `_orbit_migrations`). See
`docs/guides/migrations.md`. A database whose schema is newer than the
program is refused at startup: if `_orbit_migrations` holds a version this
program does not declare, it prints the version and exits non-zero instead of
running old code against columns it cannot describe. `migrations down "<SQL>"`
undoes its forward line, and `ORBIT_MIGRATE_DOWN=<version>` rolls back every
applied version above it at startup, newest first, then stops. What does not
exist: a standalone `orbit migrate`.

## Multipart uploads save files to disk

`req.file(field_name, dest_dir)` now parses `multipart/form-data`
boundaries, matches the part by `name=`, sanitizes the part's
`filename=` (path stripped, safe chars only), and writes the part
payload to `dest_dir/<name>`. Returns the saved path or "" when the
request is not multipart or the field is absent. Binaries containing
NUL bytes are length-delimited on the wire but cannot round-trip as
`orbit_string`. Treat them as saved bytes. Pinned by
`runtime/test_upload.c`.

## Cluster is single-host only

`orbit cluster` starts N copies of one service on this machine.
There is no shared state, no proxying, no failover, and no
multi-host story. `up`, `status`, and `down` are verified in the
deploy tutorial. `drain` and rolling restart follow the platform
rule below.

## No joules on Windows

Energy is reported in joules only where sensors exist (Linux
RAPL). On Windows the proxy is CPU time plus memory -
never converted to joules with a universal factor. The measurement
record in [Resource and Energy Measurement](ENERGY.md) enforces this.

## Latency percentiles are bucket edges

`system.latency_p50_us()`, `latency_p95_us()`, and `latency_p99_us()`
exist alongside uptime, pid, worker count, total requests, and mean
latency. They read a 100 µs-resolution histogram (1 ms-wide buckets
up to 100 ms, then an overflow bucket answered from the recorded
maximum). So a reported p99 is the boundary of the bucket holding 99%
of requests, not a measurement of one request. Anything past 100 ms
collapses into a single bucket and reports the max. Requests are split by
class at the send path: `system.http_requests_ok()` counts responses below
400 and `system.http_requests_error()` counts 400 and above.
`/_ledger` adds per-route request counts, mean milliseconds, and DB
share.

## Windows drain is kill

Graceful shutdown (drain in-flight requests, then exit) runs on
POSIX through SIGTERM. On Windows the stop is `TerminateProcess`:
immediate, with in-flight requests lost. `drain` and the graceful
phase of `restart`/`down` are best-effort stops there.

## Two servers, one port: Windows refuses it, Linux shares it

On Windows the listener is created with `SO_EXCLUSIVEADDRUSE`, so a second
process on the same port prints `Port N is not available. Another program may
be using it.` and exits 1. On Linux the listener sets `SO_REUSEPORT`, so a
second process binds and the kernel distributes connections between the two.
That is what lets a restart overlap the old process; it also means a port
mistake there splits traffic instead of failing. `ss -lntp` (or `netstat -ano`
on Windows) names the process holding the port.

## A generic model monomorphises; the type argument is inferred, never written

`model Box[T] { v: T }` works. The type argument comes from the value
written for the field that uses it, and each instantiation is its own C
struct:

```console
$ cat box.orb
model Box[T] { v: T }
fn main() -> int { val b = Box { v: 1 }  print(b.v)  return 0 }
$ orbit check box.orb
Checked box.orb: no errors.
$ orbit build box.orb -o box && ./box
1
```

`Box { v: 1 }` is `Box_int` and `Box { v: "hi" }` is `Box_string`, and the
generated C says so:

```c
typedef struct Box_int { orbit_int v; } Box_int;
static inline Box_int* orbit_model_Box_int_create(OrbitArena* arena_, orbit_int v);

typedef struct Box_string { orbit_string v; } Box_string;
static inline Box_string* orbit_model_Box_string_create(OrbitArena* arena_, orbit_string v);
```

There is nothing new in the emitter. An instantiation is an ordinary
model whose fields are already substituted, so it goes out through the
code that has always emitted a model struct. `mapTypeToC` is handed
`int` where the declaration said `T`. It still has no case for `T`, and
still does not need one. The generic declaration itself is never emitted.

**Why the literal infers but a signature names.** There is no grammar
for a type argument at an *expression* site: `Box<int>` lexes as a
comparison, and adding that grammar is a far bigger change than the
feature is worth. An annotation is a different position -- `parseTypeName`
already reads `list<string>` -- so a signature may write the argument out:

```orbit
model Box[T] { v: T }
fn take(b: Box<int>) -> int { return b.v }
fn make() -> Box<int> { return Box { v: 3 } }
```

`Box<int>` is not decoration. It names the instance the literal infers, and
the checker and the emitter have to agree on that string. Otherwise the program
passes `orbit check` and reads the wrong member. So the instance name is
built by one function in `literal.orb`, which both sides import -- the same
reason that module exists. `Box` with NO argument is still refused in a
signature (n51). A signature is written before any value exists, so there
is nothing to infer from, and the emitter would be handed a struct name
that only ever exists as `Box_int`.

### What is still refused, and where

| you write | what happens |
|---|---|
| `Box { v: 1 }` | `Box_int`. The supported spelling. |
| `Box(1)` | [E1003](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity). The positional form has an argument and no way to call it an int. (n47) |
| `fn take(b: Box<int>)`, `-> Box<string>` | Supported. The written argument names (and creates) the instance. |
| `fn take(b: Box)` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch). Nothing to infer from before the value exists; write the argument. (n51) |
| `model Box[T: int]` | Parser error. A constraint is a promise about an argument this language infers, so there is nothing to hold it to. (n53) |
| `model Phantom[T] { id: int }` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch): no field's declared type mentions `T`, so there is no value to take the argument from. `void*` would compile, and would be a lie about the model. (n52) |
| `Same { a: 1, b: "s" }` where `model Same[T] { a: T, b: T }` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch). `a` fixes `T` at `int` and `b` is then checked against it. (n50) |
| `model Box[T] { v: list<list<T>> }` | `T` is not determined. Only a field declared `T`, or a `list<T>` whose value is a list literal, fixes an argument. |
| `union Option[T] { ... }` | Still a parse error: `union` has no type parameter list at all, and substitution is wired for model fields only. This is what keeps `std/quarantine/option.orb.quarantined` quarantined. |

Two parameters work, and two instantiations of one model in one program
are two structs:

```orbit
model Pair[A, B] { left: A, right: B }
val ints = Pair { left: 1, right: 2 }      // Pair_int_int
val strs = Pair { left: "a", right: "b" }   // Pair_string_string
```

**A field read has to be typed off its owner.** This is worth knowing
because it was a live defect and monomorphisation made it easy to hit.
Two models declaring the same field name with different types used to
type each other's member reads from a module-wide scan of field *names*,
last match winning. `Pair_int_string` and `Pair_string_int` both have a
field called `second`, so any program instantiating one generic model
twice walked straight into it. The read is now typed from the model the
field reference names, which the builder had been writing down and the
backend had been discarding.

## `std/` is 20 modules; the six deleted ones are not coming back

**20 modules, and all 20 compile into one binary.** Verified:
`tests/std/test_imports.orb` imports nineteen of them into a single program
and calls into each, and it passes. The twentieth, `std/sys/arena.orb`, takes
an arena instance and is exercised by `tests/std/color_smoke.orb` and
`examples/std_imports.orb` instead. `tests/std/` is 23 files and runs 23/23 green.

`std/` was 20 modules. **Six were deleted, and the reason was measured**:
each was a function that returned a value and was not computing it:

| deleted | why it had to go |
|---|---|
| `std/sys/crypto/hash.orb` | `fnv1aHash` was `1469598103 + data.len()`, so `fnv1aHash("hello") == fnv1aHash("hellp")` was **true**. `generateKynxToken("user42")` derived a security token from the *length* of the seed. |
| `std/sys/bytes/buffer.orb` | `appendByte` stored nothing, and `readAt` returned 1/0 and never returned the byte. `writeU16LE`/`writeU32LE` cannot be repaired either: a NUL byte vanishes from a string, measured — `from_char(65) + from_char(0) + from_char(66)` is length 2. `std/bytes/bytes.orb` already owns a working version. |
| `std/sys/net/socket.orb` | There is no socket API anywhere in the language or the runtime. `bindAddress` returned `true` for a valid port on a socket whose `fd` is 0, i.e. stdin. |
| `std/sys/io/io_threading.orb` | No thread primitive exists in the lexer or the runtime. `createPool` set `is_active: true` and `dispatch` incremented a counter. |
| `std/core/memory.orb` | `alloc` returned a null pointer and `free` was a no-op. |
| `std/core/result.orb` | `result` is already a builtin with `ok`/`err`. An unparseable shadow of a working builtin. |

**One is quarantined rather than deleted**, as `*.orb.quarantined` in
`std/quarantine/`, and it is a file the language cannot read today:

| quarantined | the language feature that does not exist |
|---|---|
| `option.orb.quarantined` | a generic tagged union. `union` has no type parameter list, nothing infers the argument at construction, and the variant registry is flat by variant name. A generic `model` is not the same case: it monomorphises today. |

`bitwise.orb.quarantined` used to sit here too, and it was the
counter-example to the rule below: a syntax slip (`val` as a parameter
name), not a missing feature. It is `std/sys/bytes/bitwise.orb` again,
with `tests/std/test_bitwise.orb` over the vectors its header published.

They are not `.orb` on purpose: `.orb` is the toolchain's marker for
loadable source. A file the parser cannot read breaks
`orbit fmt --check std` on every run and can only be `import`ed to
produce a parse error. A quarantined module is not deleted because
deleting loses the only written record that the feature was wanted. The
git history alone does not say *which* feature or *why* it is
impossible. `std/quarantine/README.md` has the convention and the
"what does not belong here" list.

`std/fs/file.orb` creates directories (`mkdirAll`, parents included, true
when the directory is already there) and walks a tree. `std/string/string.orb`
parses a float (`parseFloatChecked`, canonical decimal form only, with a
diagnostic instead of `atof`'s silent prefix read). Both are pinned by
`tests/std/test_fs.orb` and `tests/std/test_string.orb`.

`std/json` parses strict JSON into typed values: `parseJson` answers `err`
for malformed input rather than a partial document, and the `json*` getters
read ints, floats, bools, strings, nested objects and indexed arrays. It is
pinned by `tests/std/test_json.orb`. What is still absent: `Option`. The
modules that claimed the rest are gone or quarantined, and
[LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#stdquarantine-specified-not-implemented)
names the absences.

## A list carries an element type now, and the checker enforces it

This entry used to be a description of a hole: eight programs that segfaulted
or silently misbehaved. The hole is closed for the receivers the checker can
name. Annotations, literals, pushes and reads are all compared while compiling
([`E1005`](ERROR_CODES.md#e1005--call-argument-type-mismatch) at calls, [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch) at pushes, reads and bindings). An empty `[]` plus
pushes is typed by first-push-wins. `int` widens into `list<float>`, but the
reverse is refused. The before/after table was the fix's own evidence and now
lives in git history with it. What is left is a different and smaller hole:

### What is still untyped

- **A `list` parameter declared without its element.** `fn read(xs: list, i: int)`
  has nothing to check a read against, and that spelling stays lenient on
  purpose, the way `unknown` is. Dynamic values cannot be refused
  without breaking code that works. The crash it used to hide is closed
  ([F-0009](ERROR_CODES.md#f-code-index), fixed): generic functions fix the
  element per call site and `tests/negative/n39_list_parameter_has_no_element_type.orb`
  pins that the incoherent call is refused. A model field is no longer in this bullet:
  `model Bag { xs: list<string> }` parses, because `parseModelDecl` reads a field
  type through `parseTypeName`, and a read through it is typed by the field's
  declaration.
- **An element this pass could not type.** `unknown` on either side is accepted,
  as everywhere else in the checker: an unknown is an inference gap, and
  refusing it would turn every gap into an error at every use.
- **A model or a union as the element.** `list<Point>` is checked for
  pointerness and nothing more. The fields of the value are not checked against
  the model's declaration here.
- **A heterogeneous list.** Not expressible in this list, and that is
  a decision about the representation (one boxed element per slot) rather than a
  gap in the check. See
  `tests/negative/list_mixed_element_kinds.orb` for why a boxed element would
  still not make `getOr(l, 0, "d")` legal.
- **The runtime refusal is still the backstop**, and it is still reachable -
  the field case above is the reachable one. It is no longer reachable by any
  push the front end could type, which is the intended end state: a diagnostic
  beats an `exit 2` with no line number.

### An object field read is lowered from the writes in the reading function

`{ "a": 1 }.get("a")` no longer lowers to a list read. It reads the field the
same way a dynamic object is written: the emitter picks the getter from the
setter that wrote that key, so an int field reads back an int, a string field
a string, and a list field a list. That scan only sees the writes in the
function the read is in.

A read whose declared type names one of the kinds an object field holds
(`int`, `float`, `bool`, `string`, `object`, `list`) carries that kind to the
emitter on the read itself, as `IRInstruction.fieldKind`. So
`val ratio: float = o.ratio` reads `0.5` and `val v: int = o.get("missing")`
answers `0`. A key that is absent is not a mismatch, and every typed getter
already answers the zero of its kind for one. The scan still wins wherever it
has an answer, so a same-function literal read is lowered exactly as before.

A read with no declaration is refused, not guessed. Both of these exit 1 from
`orbit check`, with the field named and the fix spelled out:

```orbit
val o = make()
val r = o.ratio          // object field 'ratio' has no known type in fn 'main'
print("${o.deep.x}")     // object field 'deep' has no known type in fn 'main'
```

The message asks for the declaration that supplies the missing answer:
`val deep: object = o.deep`. The value model is one machine word with no tag,
so at run time a dynamic field's kind is not recoverable, and a getter chosen
by guessing would read the wrong width. A tagged value model is the change
that would remove the requirement.

## 29.1% of instructions are `unknown`, and 45.5% of those are silent

`scripts/unknown_census.py`, run on 2026-11-01 over 206 files and 86,942
instructions. The ratchet baseline (`scripts/baselines/unknown_count.json`)
only lets the numbers fall, so this is the measured state:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 25,276 | **29.1%** |
| ...with no diagnostic at all | 11,491 | **45.5% of the unknown** |

The 11,491 silent instructions are the measured number. Five diagnostics fire
beside the opcodes they annotate: [E2001](ERROR_CODES.md#e2001--unknown-identifier-frontend)
(unknown identifier, 12,568), [E2002](ERROR_CODES.md#e2002--incompatible-binary-operands-frontend)
(binary operands, 1,171), [E2003](ERROR_CODES.md#e2003--invalid-unary-operand-frontend)
(unary operand, 46), E2004 (member, 4,789) and E2005 (call result, 6,702).
`call` and `member` are the two places where the front end does not know it
has failed, and the same classification error as the list problem above. This
is the same measurement as the root-cause table that used to live in
[nineteen programs the compiler should reject](#the-silent-group-is-empty),
and it is what the nineteen entries there were made of.

Separately, [E3001](ERROR_CODES.md#e3001--expression-cannot-be-lowered-frontend) "expression cannot be lowered to TIR" fired 9,121
times on this corpus. That is a whole class of expression the front end gives
up on, and it is not in the unknown total because there is no instruction to
type. Worst file by share: `compiler/front/parser.orb` at 47.8% (2,507 of
5,242). Re-run the census rather than trusting these numbers.

Two tools, and the difference matters. `unknown_census.py` is the
**measurement** and never fails anything. `scripts/unknown_ratchet.py`
is the **gate**: it reads the census output, compares two of the
numbers against a committed baseline in `scripts/baselines/`, and
fails if either went *up*. It does not fail because the count is high -
29.1% is the number the type work has to be scoped against, and a
zero-bar gate is a gate everybody deletes. Example run (numbers move.
The baseline file is current, this transcript is not):

```console
$ python scripts/unknown_ratchet.py --compiler <orbit> --cc gcc
  unknown_per_mille               291  baseline    297  -6
  silent_per_mille                132  baseline    136  -4
Finished unknown-count: 291 (baseline 297, ratchet holds)
```

Raising a baseline is a deliberate act: `--write-baseline` refuses to
move a number up unless `--allow-regression` is also passed. So the
count can only go down, which turns "do not regress this" from a rule
people follow into a property the build enforces.

## The frontend gate is 7/7

`scripts/frontend_gate.py` runs seven fixtures and all seven pass (two of
them, `syntax_error.orb` and `unresolved_type.orb`, could not build for most
of this cycle, and both missing imports are fixed). `print_pipeline.orb` pins
`call void print`, which is what made `orbit frontend examples/hello.orb`
fail before.

## `lib/net.orb` is gone

`lib/net.orb`, `lib/sys/linux.orb` and `lib/sys/windows.orb` were an
unspecified socket-wrapper sketch nothing imported (its event loop was
`while running { ... running = false }`). Deleted, not quarantined:
`std/quarantine/` is for specified features the language cannot express yet,
and no document specifies a socket API. `std/sys/arena.orb` (real, used by
`examples/` and `tests/std/`) was not touched.
