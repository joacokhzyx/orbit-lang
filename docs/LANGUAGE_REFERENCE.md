# Orbit language reference

Orbit source files use the `.orb` extension. This reference covers what the `0.1.0` compiler does today. The language is pre-1.0, so pin your dependency to a specific release candidate and expect gaps - I document limits alongside features.

## Program structure and functions

Functions use `fn`, typed parameters, and an optional return type.

```orbit
fn add(left: int, right: int) -> int {
    return left + right
}

fn main() {
    print("Orbit")
}
```

Use `async fn` where an API accepts an asynchronous declaration. Top-level
declarations include `fn`, `model`, `enum`, `union`, `type`, and `route`. A
top-level `val` or `const` is also accepted when its value is an int or bool
literal (a constant with file scope, emitted as a C `#define`); anything else
at file scope is rejected with E1007.

```orbit
val CHAR_SPACE = 32
const MAX_RETRIES = 3
```

## Variables and types

`val` creates an immutable binding. `var` is also accepted; add `mut` when a
binding must be mutable. Type annotations are optional when inference is enough.

```orbit
val name = "orbit"
val retries: int = 3
var mut total: int = 0
```

Core scalar types include `int`, `float`, `bool`, and `string`. Use models for
named records, enums for closed alternatives, unions for tagged alternatives,
and `type` for aliases. Containers accept an element parameter in the
annotation - `val names: list<string>` and `fn first(l: list<int>)` - and the
checker enforces what flows through it.

```orbit
model User {
    id: string
    active: bool
}

enum Role { Admin, Member }
type UserId = string
```

The lowercase names are the type names the compiler knows: `int`, `float`,
`string`, `bool`, `void`, and `list`/`map`/`object`/`result`/`response` as
container and result spellings. `List`, `Map`, `Result` and `Response` are
accepted capitalised and are the same four types. **Any other capitalised
spelling is not a type at all**, and that is now a diagnostic rather than a
surprise in the C step: `val n: Int = 1` is `E1006, Nothing declares a type
named 'Int'`, with the note that types are written in lower case or declared
with `model` or `union`. `Float`, `String`, `Bool`, `Void`, `Any` and
`DateTime` are refused the same way.

Two cases are worth spelling out because the check is not a spelling test:

- A **capitalised** name is a type only if a `model`, `enum`, `union` or alias
  declares it, or it is one of the four real container spellings above.
- A **lower-case** name that nothing declares is refused by the other half of
  the same check, which compares the annotation against the value: `val n:
  widget = 1` is `'n' is declared widget but the value is int`. The
  distinction is the useful one — `Int` looks like a type and is not one,
  while `widget` is a name the program forgot to declare.

Integer literals accept binary (`0b101` is 5), hex (`0x1F` is 31), digit
separators (`1_000` is 1000) and exponents (`1.5e2` is `150.0`, `1e-3` is
`0.001`). An exponent produces a float, always: `1e2` is `100.0`, not `100`,
because the value it denotes has a fractional part even when it prints without
one.

### Annotate your bindings

**An Orbit value is one machine word with no tag on it.** The compiler picks the
C cast from the static type alone, and a binding you did not annotate is assumed
to be a string wherever it crosses a `string` boundary. Nothing checks it at
runtime, because there is nothing to check:

```orbit
fn takesStr(s: string) -> int { return s.len() }
fn g() -> int { return 11 }

fn main() -> int {
    print(takesStr(g()))   // orbit check: no errors. Run: segfault.
    return 0
}
```

Annotate the binding, or annotate the parameter's caller, and the mistake
disappears. The same gap is why `print` truncates a `float`: `print(1.5)` gives
`1`, and `1.5 + 2.0` gives `3`.

The mechanism, the emitted C, and the other places it bites are written up in
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag).

### Strings

An ordinary `"…"` string processes escapes, so `\"` is a quote, `\n` a newline,
`\t` a tab, `\\` a backslash and `\xHH` a byte.

A **raw string**, triple-quoted like Python, processes nothing at all:

```orbit
return """{"status":"ok","count":42}"""
```

That is the form to reach for when the payload is JSON, because it removes the
escaping that makes JSON unreadable. Compare:

```orbit
return "{\"status\":\"ok\",\"count\":42}"   // every quote doubled
return """{"status":"ok","count":42}"""     // none of them
```

Three rules, and that is all there is:

- **The first `"""` after the opening one closes the literal.** So a single
  quote inside is ordinary content: `"""a"b"""` is `a"b`.
- **No escapes exist.** A backslash is a backslash, so a Windows path needs no
  doubling: `"""C:\Users\orbit"""`. The only thing that cannot appear inside is
  a literal `"""`, which no JSON or prose needs; split the string or use an
  ordinary `"…"` for that.
- **Newlines are kept**, which is what makes a multi-line body readable and
  served the way it is written:

```orbit
return """{
  "items": [{"id": 1}, {"id": 2}],
  "total": 2
}"""
```

Both forms are ordinary `string` values at runtime, so they concatenate and
compare like anything else. An unterminated `"""` is reported as an error rather
than silently swallowing the rest of the file.

### Integers

Decimal is the base. Two conveniences exist, and both used to be wrong in the
way that costs the most: they compiled, ran, and produced a plausible number
that was not the one written.

```orbit
val mask = 0xFF          // 255, and 0xff / 0xAbCdEf likewise
val big = 1_000_000      // one million; _ is only a separator
```

Before, `0xFF` lexed as the integer `0` with `xFF` dropped, and `1_000_000`
lexed as `1`. Both passed `check`. A bitmask written that way is a bug that
survives to production.

### Interpolation

`${…}` inside a string is substituted, in both string forms. That is what
handles the part of a body that is only known at runtime:

```orbit
val n = 3
print("items: ${n}")
return ok 200 """{"count":${n},"path":"C:\dir"}"""
```

Rules:

- A hole may hold a **string, int, float or bool**. Anything else - a model, a
  list, a map, a `result` - is a compile error rather than a guess, because
  there is no text that is obviously right for it.
- Braces nest and quotes are tracked, so `${show("}")}` is an expression whose
  argument is `}`, not a hole that ended early.
- There is no escape for `$`. `\${` is a backslash followed by a hole.
- `"${n}"` is a string, not the `int` it interpolates.
- The result is an ordinary string and can be concatenated, compared or returned
  like any other.

## What Orbit does not promise about values

This section is for the person who has already been bitten. It is not a
description of the type system; it is a list of things the language will
not tell you, written as a rule you can follow rather than as a warning
you can only read once. The mechanism underneath is
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag);
the measured list of programs that compile and compute the wrong answer
is in [known limitations](KNOWN_LIMITATIONS.md#nineteen-programs-the-compiler-should-reject-and-does-not),
which you should read before you rely on any of this.

### An `int` is 32 bits and it wraps silently

`orbit_int` is 32 bits. Overflow is not an error, is not diagnosed, and
gives you a different number:

```orbit
print(2147483647 + 1)   // -2147483648
print(46341 * 46341)    // -2147479015
print(65536 * 65536)    // 0
```

All three are what C does, so the wrapping is at least consistent. Two
things follow that C does *not* give you. First, the compiler never warns
you, so a value that went out of range in the middle of a calculation
keeps going with the wrapped one. Second, an integer **literal** used to be
folded with no range check at all, so the mistake was baked in before your
program started. That one is fixed in the tree and not yet in a release:

```orbit
print(2147483648)       // -2147483648
print(4294967296)       // 0
```

If you need a wider integer, there is none today.

### `+ - *` and `/ %` do not agree about a negative operand

Fixed in `672151c` and in the compiler as built from this tree; **not yet
in a release**, so the numbers below are what `0.1.0-rc.2` gives. `+`, `-`
and `*` are correct for negatives. `/` and `%` were not, because integer
division and remainder were emitted with both operands cast to an unsigned
64-bit type, so a negative dividend was divided as a large positive number
and only its low 32 bits survived:

```orbit
print((0 - 7) / 2)      // -4. It should be -3.
print((0 - 7) % 2)      //  1. It should be -1.
print((0 - 7) / 3)      // 1431655763. It should be -2.
```

And note how carefully that is written: **the parentheses are required.**
`0-7 / 2` is not this bug. It parses as `0 - (7/2)`, which is correct, and
prints `-3`. The unparenthesised form is a different program that looks
identical, so do not rule this out by testing it without them.

**Rule: do not use `/` or `%` on a value that can be negative** until the
next release. Compute the magnitude, divide, and apply the sign yourself.

### A list slot has no element type, so nothing can check it

`OrbitList` is `{ void* data; size_t len, capacity, elem_size;
OrbitArena* }` (`runtime/types.c:195-201`). One pointer per element, and
nothing anywhere records what that pointer points at. There is therefore
no type to check an element against, and no diagnostic to give:

```orbit
var l = []
l.push(10)
l.push("twenty")
print(l.len())          // 2 - correct
print(l.get(0))         // 10
print(l.get(1))         // a heap address
```

`orbit check` reports no errors. The first element reads back correctly
because the stored word *is* the integer, which is why a two-element test
usually passes; the second is a string address read as a value.

**Rule: one list, one element type, and only you know what it is.** Never
hand a list to a function whose parameter says `string` unless every
element is a string — the helper cannot check, and the failure is a
segfault in your code rather than a diagnostic at the call. Use `.get(i)`,
never `.at(i)`; `.at` on a list answers 0. See
[collections](#arrays-elements-and-accessors).

### An int-to-pointer cast is a guess, made by name and shape

When the backend has to move a value between an `int` and a pointer, it
picks the cast from the static type alone, and where there is no static
type it classifies the value by **its name and its shape** rather than by
anything it can check. That classification is right often enough to be
dangerous, because when it is wrong the program still compiles.

This is not a warning about a sharp edge you can see. It is the reason
`["alpha","beta"].at(1)` returns 0, the reason a field read on an
untyped value can come back with the wrong field, and the reason a
capitalised type name like `Int` type-checks and then fails in the C step.
[Known limitations](KNOWN_LIMITATIONS.md#nineteen-programs-the-compiler-should-reject-and-does-not)
has the measured list.

**Rule: annotate the binding when you read it back.** `val xs: list = …`
and `val n: int = f()` cost one token each, and they are the difference
between a guess and a check. An unannotated `val` is `unknown` for the
rest of the pipeline, and **29.0% of the instructions the front end emits
are `unknown`** — so the unannotated case is the common one, not the
exotic one. Annotating a binding is therefore not a nicety: it is what
lets the next check fire.

### The short version

| you write | what you can rely on |
|---|---|
| `int` arithmetic that fits in 32 bits, all non-negative operands | correct |
| `int` arithmetic that overflows | wraps, no warning |
| `int` division or remainder with a negative operand | wrong in `0.1.0-rc.2`; fixed in `672151c`, unreleased |
| a literal outside the 32-bit range | a different number in `0.1.0-rc.2`; fixed in tree, unreleased |
| a list's element type | whatever you put there; nothing checks it |
| `.get(i)` on a list | bounds-checked; `NULL` past the end |
| `.at(i)` on a list | **wrong** — reads the list struct, use `.get` |
| a cast between `int` and `string`/`pointer` | whatever the compiler guessed |
| an unannotated `val` | `unknown` downstream; annotate it |

None of this is a reason not to use Orbit. It is a list of the places to
put an assertion or an `if` that the compiler will not put there for you.

## Control flow

Orbit supports `if` / `else`, `while`, and iteration with `for … in`. `break`
and `continue` are valid within loops. There is no unconditional `loop`; the
keyword is reserved but a `loop { }` body is a parse error, so use `while true`
when you mean that.

```orbit
var mut sum = 0
for item in [1, 2, 3] {
    sum = sum + item
}

while sum < 10 {
    sum = sum + 1
}
```

Expressions support arithmetic, comparisons, `&&`, `||`, unary `!` and `-`,
calls, member access, arrays, [object literals](#object-literals), and string
interpolation.

### `if` is also a value

An `if` is one construct with two uses, and they are the same construct: a
statement that runs a branch, and an expression whose value is the value of the
branch that ran.

```orbit
val label = if score >= 90 { "A" } else { "B" }
print(if ready then "go" else "wait")
```

Both branch shapes work in both positions, so nothing has to be rewritten to
move an `if` from one to the other:

| branch | written as | value of the branch |
|---|---|---|
| a block | `if c { … }` | the value of its **last statement** |
| an expression | `if c then a`, or `if c a` | the value of `a` |

```orbit
// The same `if`, three ways, all worth the same thing.
val a = if c then 1 else 2
val b = if c 1 else 2
val d = if c {
    1
} else {
    2
}

fn classify(n: int) -> string {
    if n < 0 { return "negative" }   // a statement: no value wanted
    return if n == 0 then "zero" else "positive"   // a value
}
```

Rules worth knowing:

- **`else` is required where a value is wanted.** `val y = if c 1` is
  `E0302`: the false path would have no value to give. As a statement, an `if`
  with no `else` is fine.
- **Only the branch that runs is evaluated.** The other one has no effect at
  all, so a call, a write, or an `ok`/`err` in the untaken branch does not
  happen.
- **The type of an `if` is the type of its then branch.** There is no union to
  join two branch types into, and the two are not compared, so keep them the
  same shape: an `if` that returns `"a"` in one branch and `1` in the other is
  an `if` typed `string` that sometimes holds an integer.
- **`else if` chains are one value**, in either position and either spelling:
  `if a then 1 else if b then 2 else 3`. Every `if` in the chain needs its own
  `else` when the chain is a value.
- **A branch written without braces is a single expression.** `if c val x = 1
  else 2` is `E0304`; write `if c { val x = 1 } else { 2 }`.
- **`then` is optional and is not a reserved word.** It introduces a branch, and
  it exists for the branch the condition would otherwise swallow: the condition
  is parsed as a full expression, so in `if n - 1` the `-` is a subtraction and
  the then branch is missing (`E0303`). `if n then -1 else 0` is the branch that
  means minus one. `then` is read as that keyword only when a branch follows it,
  so `then` is still an ordinary name everywhere else — as a variable, and as
  the whole branch (`if ready then else 3` is the value of `then` when it is
  true).

A block branch is worth its last statement, so a block may compute and then
answer:

```orbit
val total = if n > 10 {
    val doubled = n * 2
    doubled + 1
} else {
    0
}
```

Two shapes are **not** supported today:

- A block used as a value on its own — `{ 1 + 2 }` is not an expression. The
  "last statement is the value" rule applies to a branch of an `if` only.
- `if` inside the experimental typed front end (`orbit frontend`), which reports
  `E3001` for an `if` in expression position. The C backend path compiles and
  runs these; the TIR lowering does not model a merge value yet.

## Arrays and objects

Array literals use brackets:

```orbit
val ports = [8080, 8081]
print("${ports[0]}")
```

An ordinary string supports `\n`, `\t`, `\r`, `\"`, `\\`, and the byte escape
`\xHH` with two hex digits (`"\x41"` is `"A"`, `"\x1b"` starts an ANSI
sequence). Anything malformed stays literal.

### Object literals

```orbit
return ok {
    status: "UP"
    uptime_seconds: system.uptime()
}
```

An object literal is a **value**, not text. Read a field off it, nest one
inside another, hand it to a function - it is a `model` whose shape the
compiler learns from the source instead of from a declaration.

```orbit
val o = { name: "api", port: 8080, healthy: true }
if o.port == 8080 { ... }
val inner = { deep: { deeper: 7 } }
if inner.deep.deeper == 7 { ... }
```

What to know:

- **Fields may be string, int, float, bool or another object.** A list or a map
  is a compile error, not a guess: there is no value type to store, and
  keeping the pointer would write a pointer's digits into the response. If you
  need a list in a response body, interpolate it into a raw string - and read
  [Arrays: elements and accessors](#arrays-elements-and-accessors) first, so
  you know what a list actually holds.
- **Key order is the order you wrote**, not a hash order, so a response body is
  byte-for-byte what the source says.
- **Everything inside is escaped on the way out**, which is the thing a
  hand-written JSON string cannot promise.
- A key may be a keyword - `{ ok: true }` is fine - or a quoted string, so
  `"content-type"` works as a key. Reading a dashed key back with
  `h."content-type"` is not supported yet: the name comes back from the parser
  with the dash turned into an underscore, so the lookup misses.
- A field's type is learned from the writes **in the same function**, so read a
  field of an object that a function returned as part of a literal you can see.
- `{}` is a valid empty object.
- Separators are optional: one field per line, as above, or commas.

A named record with a fixed shape is still a [model](#variables-and-types).
Use a model when the fields are known up front and you want them checked; use
an object literal for a response body whose keys are data.

For a body that is mostly static text, a [raw string with
interpolation](#interpolation) is still shorter:

```orbit
return ok 200 """{"name":"api","port":${port}}"""
```

A body is a string or an object. A body the compiler can type as an `int`, a
`float` or a `bool` is refused with a diagnostic, because a C string parameter
cannot take it. A body it cannot type at all - an index, a call it has no
signature for, an expression whose operands do not agree - is converted to text
with the runtime helper that matches the type the compiler settled on, the same
way a `${...}` hole is. That is a fallback, not a licence: prefer a string, a
raw string, or an object literal, whose shape you wrote down.

## Arrays: elements and accessors

The runtime calls an array a `list`, and the type name is `list`. This section
is the whole of collection semantics today: what a slot holds, which accessor
reads it, and what happens at the edges.

A list holds `void*`. Not "a string, an int, or a model" - one pointer-sized
slot per element, whatever the element was:

```c
/* what a list literal compiles to */
{ OrbitResult _lr = orbit_list_create(arena, sizeof(void*), 3);
  r_0 = _lr.ok ? (OrbitList*)_lr.value : NULL; }
```

`OrbitList` is `{ void* data; size_t len, capacity, elem_size; OrbitArena* }`
(`runtime/types.c:195-201`). Nothing in the type records what a slot points at.

**`.get(i)` works, and it is the accessor to use.** It emits
`orbit_list_get`, which is bounds-checked:

```orbit
val xs = [10, 20, 30]
val n: int = xs.get(1)          // 20

val words = ["alpha", "beta", "gamma"]
print(words.get(2))             // gamma
```

Past the end, `orbit_list_get` returns an error and the generated code
assigns `NULL`, so you get a null pointer rather than an element:

```orbit
print(words.get(99))            // (null)
```

**`.at(i)` does not read an element.** It is classified as a *string* access
and compiles to `orbit_string_at((orbit_string)list, i)` - a byte read at an
offset into the list struct. It type-checks clean, which is the problem. Note
that a method call directly on a literal does not parse, so bind the list
first; the results are the same either way:

| expression | result |
|---|---|
| `[10,20,30].at(0)` | the low byte of the list's `data` pointer - I measured 48, 144 and 0 in three programs that differ only in what else they allocated |
| `["a","b"].at(1)` and above | `0` |
| `["a","b"].at(0)` bound to a `string` | segfault |
| `"hello".at(0)` | `104` - correct, this is what `.at` is for |

`.at()` on a **string** is the intended use and works: it returns the byte
value at that index, and `0` past the end. On a list it is a silent
miscompile. Use `.get()`.

An index past the end of a *string* is also silently `0`, which is the
byte value of NUL, so `"hello".at(99)` is indistinguishable from reading a
real NUL. And a list with two element types in it is not an error, because
there is no element type to disagree with - see
[what Orbit does not promise about values](#a-list-slot-has-no-element-type-so-nothing-can-check-it),
which also covers the int/pointer cast that decides what `.at()` actually
reads.

### Maps

A map literal does not build a map. `{ "a": 1 }` emits
`orbit_object_create(arena)`, and `.get()` on that object still emits
`orbit_list_get` - the key is passed where an index belongs:

```orbit
val m = { "a": 1, "b": 2 }
val v: int = m.get("a")   // orbit check: no errors. Run: segfault.
```

`orbit check` accepts all of this without a murmur. There is no map type in
the emitter's table beyond the name, and [known limitations](KNOWN_LIMITATIONS.md)
records it.

## Result values

Functions can return the built-in `result` value type. Construct successful and
failed values with `ok(value)` and `err(message, code)` in expressions:

```orbit
fn load_value() -> result {
    val value: result = ok(41)
    return value
}

fn reject_value() -> result {
    val failure: result = err("invalid input", 7)
    return failure
}
```

The expression constructors are distinct from the HTTP response forms
`return ok 200 payload` and `err 400 message` used inside routes. Result values
can be constructed and returned by the current compiler. A `result` is an
ordinary value: it can be bound to a `val`, with or without an annotation, and
passed to a function as an argument.

```orbit
fn unwrap(r: result) -> int {
    val value: int = try r catch {
        return 0
    }
    return value
}

fn read_twice() -> int {
    val bound = load_value()
    return unwrap(bound) + unwrap(load_value())
}
```

A `try` expression
propagates an error from a `result` value to the current function and yields the
successful value. A `catch` block handles the failed branch:

```orbit
fn read_value() -> int {
    val value: int = try load_value() catch {
        return 0
    }
    return value
}
```

The current handler can execute statements and return from the enclosing
function. Naming a variable after `catch` binds the error message string:

```orbit
fn read_value() -> int {
    val value: int = try load_value() catch e {
        print(e)
        return 0
    }
    return value
}
```

## HTTP services

Routes declare an HTTP method and a literal path. A route can return a successful
response with `return ok`, or terminate with an HTTP error through `err`.

```orbit
route GET "/health" {
    return ok 200 "{\"status\":\"ok\"}"
}

route GET "/private" {
    err 401 "unauthorized"
}
```

Path segments starting with `:` or wrapped in `{...}` capture one
non-empty segment, readable with `req.param("name")`; `*` matches one
segment without capturing. A static route always wins over a param
pattern covering the same path. Values are matched raw (no
percent-decoding); a trailing slash is tolerated.

```orbit
route GET "/notes/:id" {
    val id = req.param("id")
    return ok 200 "{\"note\":\"" + id + "\"}"
}
```

Routes can carry a per-route rate annotation after the path, before the body:

```orbit
route GET "/heavy" limit 100/min burst 20 {
    return ok 200 "{\"status\":\"ok\"}"
}
```

`limit` takes a positive integer rate plus an optional `/unit` window:
`min` is 60000 ms, `sec` and `s` are 1000 ms, `ms` is 1 ms; with no
`/unit` the window is 1000 ms. `burst` is optional and sets the bucket
capacity; when omitted (or zero) it defaults to the rate. The compiler
rejects a `limit` whose rate is not `> 0`, whose window is not `> 0`, or
whose burst is negative. Routes without `limit` fall back to the global
gate only (see `docs/KYNX.md`). The runtime keeps at most 32 annotated
routes; a 33rd annotation is dropped at startup and counted in the
`kynx_route_limit_drops` perf counter, while a repeated identical
annotation is idempotent.

The runtime includes HTTP, authentication, JWT, crypto, file, and server support.
Their API surface is under active development. Check the runtime and examples
before depending on a new helper in a public service.

## SQLite

Orbit links SQLite through its runtime. Models provide schema metadata and the
runtime exposes database operations to generated programs. SQLite is usable for
embedded service storage, but migrations, transaction boundaries, backups, and
input validation remain application responsibilities. Do not build SQL strings
from untrusted input; prefer the parameterized runtime operations where available.

## Modules

Import by path. Relative imports resolve against the importing file,
then the working directory:

```orbit
import "./helpers.orb"
```

Standard library imports use the canonical `std/...` (or `lib/...`)
spelling and resolve against the std roots in order: the compiler
binary's directory, its parent, then the working directory. Run
builds from the repository root so `std/` resolves:

```orbit
import "std/sys/term/color.orb"
```

All `std` paths are lowercase (`std/<area>/<module>.orb`). The catalog
grows module by module, each with an example, tests under `tests/std/`,
and docs. Until it covers your need, keep module boundaries small and
pin the compiler version in CI.

**Read [Writing a library others can import](LIBRARIES.md) before you publish
one.** The import namespace is global, a name may be declared only once across
the whole import graph, and `private` does not restrict anything.

## Standard library (Wave 1)

Shipped and tested under `tests/std/` (run with
`test_suite.py --dir tests/std`):

- `std/test/assert.orb`: `assertTrue`, `assertEqInt`, `assertEqStr`
  for exit-code tests. No `assertErr`: a result passed as an
  argument works, and try/catch on a result parameter works
  inline, but the pair is not yet exercised (STAB-9).
- `std/string/string.orb`: `trim`, `startsWith`, `endsWith`, `join`,
  `split`, `padLeft`, `padRight`, `toUpper`, `toLower` (byte-wise,
  ASCII-only), `parseIntChecked` (canonical decimal only; returns
  `result`, consume with inline try). `orbit_string_to_int` is bound by the `.to_int()` method on strings.
- `std/hash/hash.orb`: `sha256Hex`, `hmacSha256` (runtime bindings).
  No `fnv1a32`: bitwise operators have no lexer tokens yet. There used
  to be an `std/sys/crypto/hash.orb` claiming to provide it, and it is
  gone: its `fnv1aHash` was `1469598103 + data.len()`, so
  `fnv1aHash("hello") == fnv1aHash("hellp")` was true, and
  `generateKynxToken` derived a security token from the *length* of the
  seed. Real FNV-1a of `"hello"` is 1335831723.

Bind a fallible std result to a `val` if you need to use it twice, or
pass it straight to a function that takes a `result`; both are
supported. What is not supported is `return ok(expr)` directly in a
function returning `result`: the parser reads `ok` after `return` as
the route response form (STAB-9), so assign it first.

`result` is a **builtin type**, not a std module. `ok` and `err` are
lexer keywords (`compiler/lexer.orb:199-200`) and the type name is one
of the six the backend knows. A `std/core/result.orb` used to shadow
it and did not parse; it is gone. If you were told to `import` it, you
were told about a file that never worked.

## Standard library (Wave 2)

- `std/collections/lists.orb`: `getOr`, `firstOr`, `lastOr`,
  `containsStr`, `containsInt`, `indexOfStr`, `indexOfInt`, `reverse`
  over builtin lists. Maps are out of scope (method lowering targets
  lists today); higher-order helpers need closures the language lacks.
  Every helper declares its payload: `fn getOr(l: list<string>, ...)` and
  `fn containsInt(l: list<int>, ...)`. A caller that can name the element
  type and passes a different one fails `orbit check` with E1005 naming
  both; a caller handing a bare `list` still runs, and the runtime aborts
  with a clear "list element type mismatch" on the first typed read
  instead of dereferencing the wrong shape (F-0002/F-0009, closed by
  `list<T>` in signatures).
- `std/fs/file.orb`: path-based `readAll` (returns `result`, consume
  with inline try), `writeAll`, `append` (read-modify-write, never
  atomic), `exists`, `removeFile`, `listDir`. No open handles, no
  buffered streams.
- `std/io/io.orb`: `supportsColor` (`NO_COLOR`/`TERM=dumb` honored),
  `gradient` with a real hex parser (bad input returns the text
  unchanged), styling in `std/sys/term/color.orb`. No `readLine`
  (needs an arena-taking binding the compiler will not inject), no
  `eprint` (no stderr builtin), no `println` (builtin `print`
  already newlines). It imports the owner of `system_env`
  (`std/sys/proc/process.orb`) and delegates to
  `wrapRgbForeground`; its own old `wrapRgb` is gone, because two
  functions with the same body and reversed argument orders is a trap.
- `std/time/time.orb`: `uptimeSeconds`, `addSeconds`,
  `elapsedSince`, `deadlineExceededSeconds`. Seconds only: no wall
  clock, no sleep, no monotonic milliseconds (Orbit ints are 32-bit).
  `uptimeSeconds()` and the builtin `system.uptime()` are the same
  counter read through the same extern - there is one clock, not two,
  so do not go reconciling them.
- `std/sys/proc/process.orb`: `pid`, `getEnv`, `getEnvOrDefault`,
  `execStatus` (verify shell codes per platform by hand),
  `exitProcess` (named to never shadow libc `exit`).
- `std/log/log.orb`: `info`, `warn`, `error`, `debug(msg, enabled)`,
  `withReq`, `toJsonLine`. No globals: context travels explicitly.

## Standard library (Wave 4)

- `std/sys/crypto/jwt.orb`: `signHs256`, `verifyHs256` (HS256 only,
  no `alg:none`; time travels explicitly as `nowUnix` because Orbit
  has no wall clock), `decodePayload` (pure base64url decode),
  `getExp`, `verifyWithKeys` for rotation. `exp` is required;
  `nbf`, when present, must not be future; `iat` is carried, not
  enforced. The SHA-256 and HMAC bindings are **borrowed from
  `std/hash/hash.orb`**, which owns them; redeclaring them here is a
  `Duplicate symbol` the moment both are in one import graph.
- `std/bytes/bytes.orb`: `newBuffer`, `appendByte`, `appendSlice`,
  `writeFrame`/`readFrame` (decimal length prefix; malformed and
  empty both read as empty), `readAt` (-1 out of range), `sliceBuf`,
  `availableRead`, `consume`, `clear`. Bytes are 1-255 (C strings
  cannot hold NUL), so there is deliberately no fixed-width binary
  framing. Shared C externs live in `std/string/string.orb`;
  redeclaring them in another module collides on merge. **`readAt`
  returns the byte, and `-1` out of range — module-wide rule, not one
  function's quirk.** There was a second `readAt` in
  `std/sys/bytes/buffer.orb` that returned `1`/`0` and never returned
  the byte; that file is gone. If you are adding a module, this is the
  contract, and a second `readAt` cannot exist anyway.
- Deferred honestly, and **not present in the tree**: `http_client` and raw
  sockets (there is no socket API in the language or the runtime — the
  `std/sys/net/socket.orb` that claimed one is gone), a `sync` pool
  (needs closures; `std/sys/io/io_threading.orb` is gone), `fnv1a32` (needs
  bitwise operators).

## `std/quarantine/`: specified, not implemented

Two things Orbit does not have are written down as
`std/quarantine/*.orb.quarantined` rather than shipped as a working-looking
module that is not. The convention and the reasoning are in
`std/quarantine/README.md`; the short version is that `.orb` means "loadable
source", so a file the parser cannot read must not carry that extension — it
would break `fmt --check` on every run and could only ever be imported to
produce a parse error.

| module | missing |
|---|---|
| `option.orb.quarantined` | a generic tagged union. The parser has no type parameter list on `union`, and there is no monomorphisation, so there is no way to build a parameterised `Option<T>` |
| `bitwise.orb.quarantined` | bitwise operators. `^` and `~` are invalid characters in the lexer; `&` and `\|` lex as tokens but are not binary operators; `<<` and `>>` lex as two tokens each |

Nothing imports these. If you are looking for `Option` or for `^`, this is
where the design is, and both entries name the exact language feature that
would let them land.

## System telemetry

`system.*` calls read live runtime counters. Every value is measured; what is
not measured is not exposed (no success/error split, no p50/p95/p99 yet).

| Call | Returns | Source |
|---|---|---|
| `system.uptime()` | `int` seconds since process start | monotonic clock |
| `system.pid()` | `int` process id | OS |
| `system.active_workers()` | `int` workers configured at startup (`0` outside servers) | server startup |
| `system.http_requests_total()` | `int` completed requests | request counter |
| `system.latency_avg_us()` | `int` mean latency, microseconds (`0` before the first request) | RDTSC cycles on the same 2.5 GHz basis as the request log; approximate on other clocks |

## Cost ledger

Every server records per-route handler cost automatically - no annotations.
`/_ledger` serves a live table (loopback only), `/_ledger/data` the same as
JSON. Columns: requests, mean ms, DB share, energy, source. Milliseconds share the request
log's approximate clock basis. The energy column reads joules per request
(estimated route share, see `docs/ENERGY.md`) where a power sensor exists,
and a labeled CPU proxy in cycles where it does not - never converted.
Paths starting with `/_` are reserved for
runtime endpoints; do not define routes there.

## Compiler commands

```sh
orbit build app.orb                # Compile to a native executable
orbit run app.orb                  # Build and run it (servers keep the terminal)
orbit check app.orb                # Parse and typecheck, no code emitted
orbit fmt app.orb                  # Format a file (writes only on success)
orbit doctor [dir]                 # Project checks (--fix writes; see DOCTOR.md)
orbit frontend app.orb             # Emit the typed IR
orbit cluster ...                  # Single-host orchestration (see CLUSTER.md)
orbit --help                       # Display the command-line help
orbit --version                    # Display the compiler version
```

[COMMANDS.md](COMMANDS.md) is the reference for this list, and the one to keep
current.

`orbit dev` (watch/reload), `orbit test`, `orbit bootstrap`, and
`--backend=` flags are not implemented. Calling them treats the word as a
filename and fails. See [Command Reference](COMMANDS.md) for the supported
list and exit codes.
