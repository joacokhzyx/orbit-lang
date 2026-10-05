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
gap you can design around. The first section is about the programs `orbit
check` refuses, which used to be the reason to distrust it: nineteen of them
translated cleanly and computed something else. All of those are diagnostics
now, and the section records what they answer instead -- including the two
checks that were wrong in the direction of refusing valid code, which is the
failure mode worth reading about.

## The silent group is empty

This section used to be called *nineteen programs the compiler should reject
and does not*, and it was the reason this document existed. Every entry in it
is now a diagnostic, so it has been replaced rather than kept as a museum.

The reason to write that down rather than just delete the heading is that the
list was load-bearing. It is the evidence that `orbit check` is worth running,
and it was produced by one command which is also a CI gate, so it could not
rot quietly:

```console
$ python scripts/negative_gate.py --compiler <orbit>
...
Finished negative: 32/32 pass (1 known defect still accepted)
```

Thirty-two programs that must be rejected, thirty-one of which are. The one
that is not is [a `list` parameter with no element type](#a-list-carries-an-element-type-now-and-the-checker-enforces-it),
which is a language design gap rather than a missing check.

What replaced the list, in the order the work was done:

| what used to happen | what happens now |
|---|---|
| `.at()` on a list read a byte of the list pointer and answered 0 | `.at()` and `.get()` both do the right thing, on ints and on strings |
| a call argument's type was never compared with the parameter's | `E1005`, naming the parameter and both types |
| an undeclared identifier printed a stack address | *Undeclared identifier: nothing in scope declares it* |
| a call with the wrong arity dropped the extra arguments | *Wrong number of arguments to f: it takes 1, got 3* |
| a model constructor accepted the wrong argument types | `E1003`, naming the field and both types |
| `1e2` was the integer `1`, `0b101` was the integer `0` | both are literal values; an exponent is always a float |
| `(0-7)/2` was `-4` and `(0-7)/3` was `1431655763` | `-3` and `-2`, C semantics, pinned by `div_mod_signed.orb` |
| `2147483648` silently became `-2147483648` | *integer literal does not fit an orbit_int* |
| `s.at(99)` answered 0, which is the NUL byte | `E1002`, naming the index and the length |
| `val v: widget = 3` was ignored | `E1006`, and a capitalised unknown type is refused too |
| `val n: Int = 1` reached gcc as `Int*` | `E1006`, with the note that types are lower case or declared |
| `m.nonexistent`, `s.radius`, `n.nothing` died in the C step | `E1003`, and the receiver's own members are the only ones |

Two of those deserve a note about *how*, because both were the same mistake
wearing different clothes.

**A check that only knows one table is a check that guesses.** `E1006` refuses
a capitalised type name that nothing declares, which is what makes `val n: Int
= 1` a diagnostic. Its first version asked the checker's two type registries,
and those registries do not hold models -- `checkModelDecl` fills
`modelFieldOwner` and `TypeDecl` never sees a model -- so it also refused
`List`, `Map`, `Result` and `Response`, which are real. Forty-three green
tests did not notice, because nothing in the suite used the capitalised
spelling. `tests/suite/type_spellings.orb` exists so that it cannot happen
again.

**The loud group is now silent too.** The table this section used to carry --
programs that translated cleanly and were rejected by the C compiler, with an
error naming a C symbol or a C struct member instead of the Orbit source --
is empty. Those messages reached the user as `orbit build: couldn't finish
the C step - this one is on me, not your code`, which is a sentence about the
compiler's feelings, not about the program. Every one of them is now an
`E1003` with a line and a column in the user's own file.

The mechanism underneath is described in
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag),
and the measurement that says how much of the front end is still untyped is
[below](#290-of-instructions-are-unknown-and-466-of-those-are-silent).


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

## Path parameters match, values are decoded

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Captured
values are percent-decoded by `req.param()`. One limit remains:
at most 8 captures bind per request. Query values (`?id=`) keep
working alongside.

## Custom tables are created, and forward DDL migrates

On startup the runtime creates the four built-in tables (`notes`,
`products`, `users`, `sessions`, plus demo seeds) and one table
per model in your program (`CREATE TABLE IF NOT EXISTS` from the
model fields: `string`→`TEXT`, `int`/`bool`→`INTEGER`,
`float`→`REAL`, an `id` field becomes the primary key). Forward
DDL now runs through `migrations "<SQL>"` lines (each once, in
declaration order, tracked in `_orbit_migrations`); see
`docs/guides/migrations.md`. What does not exist: `down`
migrations, a version-required startup check, and a standalone
`orbit migrate`.

## Multipart uploads save files to disk

`req.file(field_name, dest_dir)` now parses `multipart/form-data`
boundaries, matches the part by `name=`, sanitizes the part's
`filename=` (path stripped, safe chars only), and writes the part
payload to `dest_dir/<name>`. Returns the saved path or "" when the
request is not multipart or the field is absent. Binaries containing
NUL bytes are length-delimited on the wire but cannot round-trip as
`orbit_string`; treat them as saved bytes. Pinned by
`runtime/test_upload.c`.

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

## Latency percentiles are bucket edges, and there is no success/error split

`system.latency_p50_us()`, `latency_p95_us()`, and `latency_p99_us()`
exist alongside uptime, pid, worker count, total requests, and mean
latency. They read a 100 µs-resolution histogram (1 ms-wide buckets
up to 100 ms, then an overflow bucket answered from the recorded
maximum), so a reported p99 is the boundary of the bucket holding 99%
of requests, not a measurement of one request. Anything past 100 ms
collapses into a single bucket and reports the max. What isn't
measured still isn't exposed: there is no success/error split.
`/_ledger` adds per-route request counts, mean milliseconds, and DB
share.

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

## A generic model is a parse error: there is no monomorphisation

`model Box[T] { v: T }` used to pass `orbit check` with no errors and
then fail in the C step:

```console
$ orbit build gen.orb -o gen
  <build>:74:5: error: unknown type name 'T'
  <build>:77:63: error: unknown type name 'T'
  <build>:91:29: error: unknown type name 'T'
```

`T` reached the emitter as an ordinary type name, `mapTypeToC` has no
case for it, and the backend helpfully cast it to `void*` in register
declarations while emitting a bare `T*` in the struct and the
constructor. The parser now refuses the parameter list, so the
compiler is the one that says no, and it names the declaration:

```console
$ orbit check gen.orb
Parser error at line 1: 'model Box[T]' is not supported: there is no
monomorphisation, so a type parameter has nothing to substitute and 'T'
reaches the emitter as a C type name. Declare one model per type;
`result` carries a payload today.
```

What is still missing is the feature, not the diagnostic. Nothing
substitutes a type argument at a use site, so `Box<int>` and
`Box<string>` cannot be written and there is nothing to make distinct
C for. This is the same root cause as the quarantined
`std/quarantine/option.orb.quarantined`: `Option<T>` cannot be written
until this can.

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

## `orbit fmt` no longer splits a negative literal (fixed)

This entry was stale. The formatter keeps `return -1` as `return -1`:
a minus straight after a keyword starts a new expression and is
unary (F-0008, in `compiler/fmt.orb`). The tree no longer carries
the spread `- 1` sites the old entry warned about.

## A list carries an element type now, and the checker enforces it

This entry used to be a description of a hole. The hole is closed for the
receivers the checker can name, and what is left is a different and smaller
one, so the entry is rewritten rather than deleted.

`OrbitList` is `{ void* data; size_t len, capacity, elem_size; ... }`
(`runtime/types.c:195-201`): one pointer per element, and the header carries an
element *kind* rather than a type. The kind was already there (F-0002) and the
runtime already refused a push that disagreed with it. What was missing was that
nothing in the front end knew what the slot held, so the annotation and the
literal were parsed, carried on the AST, and never compared with anything. Every
row of the old table is now decided while compiling:

| program | before | now |
|---|---|---|
| `getOr([1,2,3], 0, "d")` bound to a `string` | **segfault** | `error[E1005]` at the call |
| `indexOfStr([[1,2],[3,4]], "x")` | `-1`, silently | `error[E1005]` at the call |
| `[10,20,30].at(0)` | the low byte of the `data` pointer - 48, 144 and 0 in three programs differing only in what else they allocated | `10` |
| `val xs: list<int> = [1,2,3]`, then `xs.push("nope")` | compiled; died at run time with `orbit: list element type mismatch` | `error[E1006]` at the push |
| `val xs: list<int> = []`, then `xs.push("nope")` | compiled; **exit 0**, with a string in an int slot | `error[E1006]` at the push |
| `var xs = []`, `xs.push(1)`, `xs.push("two")` | compiled; `exit 2` from the runtime refusal | `error[E1006]` at the second push |
| `val v: string = xs.get(0)` where `xs: list<int>` | compiled clean; **segfault** | `error[E1006]: 'v' is declared string but the value is int` |
| an object `{ "a": 1 }`, with `.get("a")` bound to an `int` | segfault | `1`, and typed by the setter that wrote the key |

**Where the element type comes from.** Four places, and they agree because each
one asks the same question in the same order. A `list<T>` annotation is a
declaration and outranks everything else - including the value it is bound to,
which is what makes `val xs: list<int> = []` work: the literal is empty and
types as a bare `list`, and the annotation is what the binding records. A list
literal whose elements all agree is `list<T>` statically. An empty `[]` plus
pushes has no declaration, so the **first** push decides, and every later push is
checked against it - first-push-wins because the checker approves a slot and the
emitter reads it back, and two answers are one bug. Assigning the name a
different list forgets the adopted type, the same way a push forgets a recorded
length.

**What the element type buys a read.** `.get(i)`, `.at(i)`, `xs[i]` and `.pop()`
answer with the slot's element, and a `for` loop declares its variable as the
element of the iterable. A read used to answer `unknown`, and `unknown` is
compatible with every annotation, so nothing could be checked at a read at all:
the annotation went on to the emitter as the destination register's type and
`print` dereferenced a number. `std/collections/lists.orb` is written in exactly
that style and its reads are now typed inside the helpers.

**One widening is allowed and one is not.** An `int` goes into a `list<float>`
and the emitter converts it on the way in, because a check with no bug behind it
is a check with no reason. The other direction truncates, and is refused.

### What is still untyped

- **A `list` parameter declared without its element.** `fn read(xs: list, i: int)`
  has nothing to check a read against, and `tests/negative/n39_list_parameter_has_no_element_type.orb`
  is still a known defect (F-0009). A model field is no longer in this bullet:
  `model Bag { xs: list<string> }` parses, because `parseModelDecl` reads a field
  type through `parseTypeName`, and a read through it is typed by the field's
  declaration.
- **An element this pass could not type.** `unknown` on either side is accepted,
  as everywhere else in the checker: an unknown is an inference gap, and
  refusing it would turn every gap into an error at every use.
- **A model or a union as the element.** `list<Point>` is checked for
  pointerness and nothing more; the fields of the value are not checked against
  the model's declaration here.
- **A heterogeneous list.** Not expressible in this shape of list, and that is
  a decision about the representation (one boxed element per slot) rather than a
  gap in the check. See
  `tests/negative/list_mixed_element_kinds.orb` for why a boxed element would
  still not make `getOr(l, 0, "d")` legal.
- **The runtime refusal is still the backstop**, and it is still reachable -
  the field case above is the reachable one. It is no longer reachable by any
  push the front end could type, which is the intended end state: a diagnostic
  beats an `exit 2` with no line number.

### An object `.get()` is a keyed read, and the key is not typed

`{ "a": 1 }.get("a")` no longer lowers to a list read. It reads the field the
same way a dynamic object is written, and the emitter picks the getter from the
setter that wrote that key, so an int field reads back an int and a string field
a string. An object literal's field types are still not recorded: nothing knows
them, so a key that was never written still answers with the type of whatever
was, and a getter chosen from no setter is the raw one. That is the remaining
gap here, and it needs the object's own field types recorded.

## 29.2% of instructions are `unknown`, and 46.8% of those are silent

`scripts/unknown_census.py`, run over 110 files and 42,017
instructions on this build:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 12,613 | **29.2%** |
| ...with no diagnostic at all | 5,684 | **46.6% of the unknown** |
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
29.2% is the number the type work has to be scoped against, and a
zero-bar gate is a gate everybody deletes. Verified here:

```console
$ python scripts/unknown_ratchet.py --compiler <orbit> --cc gcc
  unknown_per_mille               290  baseline    293  -3
  silent_per_mille                135  baseline    137  -2
Finished unknown-count: 290 (baseline 293, ratchet holds)
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


## `lib/net.orb` is gone

It used to live here, and the entry below is kept because a gate that was
4/6 and is now 6/6 is exactly the kind of number that gets copied out of an
old document. If you are reading that the socket wrapper is a known gap, it
is out of date: the file was removed rather than quarantined.

The three files -- `lib/net.orb`, `lib/sys/linux.orb`,
`lib/sys/windows.orb` -- were a design sketch for a socket wrapper that
nothing imported. It type-checked and then the generated C was rejected:

```console
  <build>:121:18: error: conflicting types for 'syscall'
  <build>:121:18: error: static orbit_int syscall(...);   // ours
     41 | #include <sys/syscall.h>                            // glibc's
```

Its event loop was `while running { ... running = false }`.

They were deleted rather than moved to `std/quarantine/` because that
directory has a rule these did not meet: a quarantined module is one that
was *specified* and cannot yet be expressed, and deleting it loses the only
written record that it was wanted. Nobody specified this one. There is no
socket API in the language or the runtime to specify it against, so keeping
three non-building files was a claim about a future that no document
committed to. `lib/arena.orb`, which is real and used by `examples/` and
`tests/std/`, was not touched.

