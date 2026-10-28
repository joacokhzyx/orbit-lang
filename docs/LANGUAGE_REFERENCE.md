# Orbit language reference

Orbit source files use the `.orb` extension. This reference covers what the `0.1.0` compiler accepts today. The language is pre-1.0, so pin a specific release and verify edge behavior before relying on it.

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

Top-level
declarations include `fn`, `model`, `enum`, `union`, `type`, and `route`. A
top-level `val` or `const` is also accepted when its value is an int or bool
literal (a constant with file scope, emitted as a C `#define`). Anything else
at file scope is rejected with E1007. `async fn` and `every` schedules are
parsed and refused: there is no async or timer runtime, so accepting them
would compile functions that return without computing and handlers that never
run. Remove `async` (the body runs synchronously as written). Drive scheduled
work from a loop or the process supervisor instead.

```orbit
val CHAR_SPACE = 32
const MAX_RETRIES = 3
```

## Variables and types

`val` declares an immutable binding. `var` declares a mutable binding. `var
mut` is accepted with the same meaning as `var`. Type annotations are optional
when inference is enough.

```orbit
val name = "orbit"
val retries: int = 3
var total: int = 0
```

A compound assignment updates a `var` in place: `total += 2` means
`total = total + 2`, and `-=`, `*=`, `/=`, `%=` work the same way. It is
sugar over the plain form, so the same checks apply (a literal zero divisor
in `x /= 0` is the same `E1004` as in `x = x / 0`).

`cond ? a: b` is an `if` used as a value with single-expression branches:
`val y = ok ? 1: 0`. It binds looser than every binary operator, nests to
the right, and branch typing is the `if`-value rule.

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

The type names the compiler knows are lowercase: `int`, `float`, `string`,
`bool`, `void`, and `list`/`map`/`object`/`result`/`response` as container and
result spellings. `List`, `Map`, `Result` and `Response` are accepted with a
capital and are the same four types. **Any other capitalised spelling is not a
type**: `val n: Int = 1` is rejected with `E1006, Nothing declares a type named
'Int'`, with the note that types are written in lower case or declared with
`model` or `union`. `Float`, `String`, `Bool`, `Void`, `Any` and `DateTime`
are refused the same way.

Two cases worth spelling out because the check is not a spelling test:

- A **capitalised** name is a type only if a `model`, `enum`, `union` or alias
  declares it, or it is one of the four real container spellings above.
- A **lower-case** name that nothing declares is refused by the other half of
  the same check, which compares the annotation against the value: `val n:
  widget = 1` is `'n' is declared widget but the value is int`. `Int` looks
  like a type and is not one, while `widget` is a name the program forgot to
  declare.

Integer literals accept binary (`0b101` is 5), hex (`0x1F` is 31), digit
separators (`1_000` is 1000) and exponents (`1.5e2` is `150.0`, `1e-3` is
`0.001`). An exponent produces a float, always: `1e2` is `100.0`, not `100`.

### Annotate your bindings

**An Orbit value is one machine word with no tag on it.** The compiler picks the
C cast from the static type alone. A binding you did not annotate is assumed to
be a string wherever it crosses a `string` boundary. Nothing checks it at
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

An ordinary `"…"` string processes escapes: `\"` is a quote, `\n` a newline,
`\r` a carriage return, `\t` a tab, `\\` a backslash, and `\xHH` a byte given
as two hex digits (`"\x41"` is `"A"`). A malformed `\x` and any other unknown
escape stay literal.

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
  a literal `"""`. Split the string or use an ordinary `"…"` for that.
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

Decimal is the default base. `0xFF` is hex (either letter case), `0b101` is
binary, `_` only separates digits (`1_000_000` is one million), and an exponent
always produces a float (`1e2` is `100.0`).

```orbit
val mask = 0xFF          // 255, and 0xff / 0xAbCdEf likewise
val big = 1_000_000      // one million; _ is only a separator
```

### Bitwise and shift operators

`&`, `|`, `^`, `<<` and `>>` take two ints. `~` takes one. Everything is a
64-bit `int`, two's-complement like the rest of the arithmetic: `~x` is
`-x - 1`, `>>` is arithmetic (`-8 >> 1` is `-4`), and `<<` drops the bits
that leave the top. A shift count is masked to six bits, so `x << 65` is
`x << 1` and `x >> 64` is `x`, never the undefined behaviour C has.

```orbit
val a = 12 & 10   // 8
val b = 12 | 10   // 14
val c = 12 ^ 10   // 6
val d = 1 << 10   // 1024
val e = ~0        // -1
val f = -8 >> 1   // -4
```

The precedence is C's grouping. Tightest first: `*` `/` `%`, `+` `-`,
`<<` `>>`, `<` `>` `<=` `>=`, `==` `!=`, `&`, `^`, `|`, `&&`, `||`. So
`1 << 2 + 1` is `8` and `1 | 2 & 4` is `1`. One consequence surprises
people: `&` binds looser than `==`, so `12 & 10 == 8` reads as
`12 & (10 == 8)`, which the checker refuses because the right operand is a
`bool`. Write `(12 & 10) == 8`.

An operand that is not an int is refused with a `Semantic error:` that
names the operand kind (`bitwise '&' takes two ints, not 'string' and
'string'`). `tests/negative/n79_bitwise_binop_string.orb` and
`n80_bitwise_not_string.orb` pin the two forms. `&` in type position is
still the pointer sigil (`&Point`) and `>>` still closes nested generics
(`list<list<int>>`): the split lives in the parser's `consumeTypeCloser`,
where types are parsed.

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

## Control flow

Orbit supports `if` / `else`, `while`, and iteration with `for … in`. `break`
and `continue` are valid within loops. There is no `loop` statement: `loop` is
a reserved keyword, so it cannot be used as a variable or function name, and a
`loop { }` body is a parse error. Use `while true` for an unconditional loop.

```orbit
var sum = 0
for item in [1, 2, 3] {
    sum = sum + item
}

while sum < 10 {
    sum = sum + 1
}
```

`for x, i in xs` also binds the position `i` (0-based) alongside the
element. `for outer: x in xs` names the loop so `break outer` (or
`continue outer`) inside any nesting hits it. A named jump to no enclosing
loop is an error quoting the label. `while` loops cannot be labeled.

`for x in lo..hi` counts ints from `lo` while the counter is below `hi`
(half-open `[lo, hi)`, empty when `hi <= lo`). Both bounds must be ints,
both evaluate once before the loop, and nothing is allocated: large bounds
cost iterations, not memory. With an index (`for x, i in lo..hi`), `i` is
the 0-based position, exactly as over a list. `..` outside a `for` header
is a parse error: a range is a way to iterate, not a value.

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

Both branch forms work in both positions, so nothing has to be rewritten to
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
  join two branch types into, and the two are not compared. So keep them the
  same type: an `if` that returns `"a"` in one branch and `1` in the other is
  an `if` typed `string` that sometimes holds an integer.
- **`else if` chains are one value**, in either position and either spelling:
  `if a then 1 else if b then 2 else 3`. Every `if` in the chain needs its own
  `else` when the chain is a value.
- **A branch written without braces is a single expression.** `if c val x = 1
  else 2` is `E0304`. Write `if c { val x = 1 } else { 2 }`.
- **`then` is optional and is not a reserved word.** It introduces a branch, and
  it exists for the branch the condition would otherwise swallow. The condition
  is parsed as a full expression, so in `if n - 1` the `-` is a subtraction and
  the then branch is missing (`E0303`). `if n then -1 else 0` is the branch that
  means minus one. `then` is read as that keyword only when a branch follows it.
  Everywhere else `then` is still an ordinary name, as a variable and as the
  whole branch (`if ready then else 3` is the value of `then` when it is true).

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

Two forms are **not** supported today:

- A block used as a value on its own — `{ 1 + 2 }` is not an expression. The
  "last statement is the value" rule applies to a branch of an `if` only.
- `if` inside the experimental typed front end (`orbit frontend`), which reports
  `E3001` for an `if` in expression position. The C backend path compiles and
  runs these. The TIR lowering does not model a merge value yet.

## What Orbit does not promise about values

The compiler does not check everything. The rules below are the gaps to code
around. The mechanism underneath is
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag).
The full list of programs that compile and compute the wrong answer is in
[known limitations](KNOWN_LIMITATIONS.md).

### An `int` is 64 bits and it wraps silently

`int` is a 64-bit two's-complement integer, from -9223372036854775808 to
9223372036854775807. Overflow in `+`, `-`, `*` and unary `-` is not an error,
is not diagnosed, and wraps modulo 2^64:

```orbit
val maximum = 9223372036854775807
print(maximum + 1)                  // -9223372036854775808
print(3037000500 * 3037000500)      // -9223372036709301616
print(4294967296 * 4294967296)      // 0
```

An integer **literal** outside that range is rejected at check time, as are a
literal `0` divisor and `INT_MIN / -1` (E1004). The minimum is written
`-9223372036854775808`. There is no integer wider than 64 bits.

### Division and remainder by zero stop the program

`/` and `%` on ints check the divisor. A divisor of `0`, and the one quotient
an int cannot hold (`-9223372036854775808 / -1`, and `% -1` with the same
dividend), do not produce a value. The program prints one line to stderr and
exits with status 2, the way an out-of-range list index does:

```
orbit: division by zero at app.orb:12
orbit: integer overflow in division at app.orb:12
```

The file is the root source file's name and the line is the line of the
operator. In code imported from another file the line is the line in that file
and the name is still the root file's. A divisor that is a constant other than
`0` and `-1` is not checked, so it costs nothing. `/` on floats keeps IEEE
semantics: `1.0 / 0.0` is infinity and never stops the program.

### A list element type is what you declare, or what the first push decides

A list carries an element type, and the checker enforces it. Declare it:

```orbit
val xs: list<int> = []
xs.push(10)
xs.push("twenty")       // error[E1006]
```

With no declaration, the first push decides it:

```orbit
var l = []
l.push(10)              // l is list<int> from here
l.push("twenty")        // error[E1006]
```

**Rule: say what a list holds when the pushes are not all one type.** An `int`
goes into a `list<float>` (converted on the way in). A float into a `list<int>`
is refused, because that truncates. See [collections](#arrays-elements-and-accessors)
for the accessor table.

### A read through an unannotated binding is decoded by assertion

An unannotated `val` is `unknown` for the rest of the pipeline, and a read
through it answers with whatever type the reader asserts rather than with
whatever the value holds.

**Rule: annotate the binding when you read it back.** `val xs: list = …`
and `val n: int = f()` cost one token each, and they are the difference
between a guess and a check. Annotating a binding is what lets the next check
fire.

### The short version

| you write | what you can rely on |
|---|---|
| `int` arithmetic that fits in 64 bits | correct |
| `int` arithmetic that overflows | wraps, no warning |
| an integer literal outside the 64-bit range | rejected at check time |
| a literal `0` divisor, or `INT_MIN / -1` | rejected at check time (E1004) |
| a `/` or `%` whose divisor is `0` at run time, or `INT_MIN / -1` | `orbit: division by zero at <file>:<line>`, exit 2 |
| a list's element type | declared, or decided by the first push, and checked |
| `.get(i)` / `.at(i)` / `xs[i]` / `.pop()` on a list | see the bounds rule under [Arrays](#arrays-elements-and-accessors) |
| an unannotated `val` | `unknown` downstream; annotate it |

Put an assertion or an `if` where the compiler puts none.

## Arrays and objects

Array literals (`[...]`) build `list` values. The type name is `list`,
optionally with an element type (`list<int>`). There is no `array` type.

```orbit
val ports = [8080, 8081]
print("${ports[0]}")
```

### Object literals

```orbit
return ok {
    status: "UP"
    uptime_seconds: system.uptime()
}
```

An object literal is a **value**, not text. Read a field off it, nest one
inside another, hand it to a function - it is a `model` whose fields the
compiler learns from the source instead of from a declaration.

```orbit
val o = { name: "api", port: 8080, healthy: true }
if o.port == 8080 { ... }
val inner = { deep: { deeper: 7 } }
if inner.deep.deeper == 7 { ... }
```

What to know:

- **A field may hold a `string`, `int`, `float`, `bool`, an object, a list of
  those scalars, or a list of objects.** A `map` field is a compile error, and
  so is a nested list (a list inside a list). `{ files: [{ name: "a.txt", size:
  29 }] }` is a list of objects and is allowed.
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

A named record with fixed fields is still a [model](#variables-and-types).
Use a model when the fields are known up front and you want them checked. Use
an object literal for a response body whose keys are data.

For a body that is mostly static text, a [raw string with
interpolation](#interpolation) is still shorter:

```orbit
return ok 200 """{"name":"api","port":${port}}"""
```

A body is a string or an object. A body the compiler can type as an `int`, a
`float` or a `bool` is refused with a diagnostic. A body it cannot type at all
is converted to text with the runtime helper for the settled type, the same way
a `${...}` hole is. That covers an index, a call it has no signature for, and
an expression whose operands do not agree. That is a fallback, not a licence:
prefer a string, a raw string, or an object literal, whose fields you wrote
down.

## Arrays: elements and accessors

This section is the whole of collection semantics today: what a slot holds,
which accessor reads it, and what happens at the edges.

**Say what the list holds, and the checker holds you to it.** A `list<T>`
annotation is the declaration:

```orbit
val xs: list<int> = []
xs.push(10)
xs.push("nope")          // error[E1006]: the value is string, the slot is int
```

A literal whose elements all agree is typed statically, and an empty `[]` with
no annotation takes its element type from the first push:

```orbit
var names = []
names.push("one")        // this push decides: list<string>
names.push(2)            // error[E1006]
```

An `int` goes into a `list<float>` (the emitter converts it on the way in). A
float into a `list<int>` is refused, because that truncates.

**`.get(i)` is the accessor to use:**

```orbit
val xs = [10, 20, 30]
val n: int = xs.get(1)          // 20

val words = ["alpha", "beta", "gamma"]
print(words.get(2))             // gamma
```

**Bounds rule:** `.get(i)`, `.at(i)`, `xs[i]`, and `.pop()` are bounds-checked.
A literal index past the end of a literal receiver is a compile error (E1002).
Any other out-of-range read aborts the process instead of answering a value.
An index past the end of a *string* answers `0`, the byte value of NUL.

`.at(i)`, `xs[i]` and `.pop()` read the same element and answer with the
element type, so `val s: string = words.get(0)` is checked rather than obeyed.
A `for` loop declares its variable as the element of the iterable. A `list`
parameter declared without its element has nothing to check a read against
(see [what Orbit does not promise about
values](#what-orbit-does-not-promise-about-values)).

### Maps

A `{...}` literal builds an object, never a map. `.get("k")` on an object is a
keyed field read, answered with the type the value was stored as:

```orbit
val m = { "a": 1, "b": "hi" }
val v: int = m.get("a")      // 1
val s: string = m.get("b")   // "hi"
```

There is no map literal syntax. `map` is a separate type name. A key nobody
wrote has no stored type to be read as.

## Result values

One grammar covers both `result` values and HTTP responses:

```
value := ok(expr) | err(expr[, expr])
stmt  := return ok [status] expr
       | err [code] expr
       | return expr
```

In expression position, `ok(v)` builds a success and `err(msg)` / `err(msg,
code)` builds a failure (the code defaults to 500). After `return`, `ok`
starts the response shorthand: `return ok [status] body` (status defaults to
200), and a bare `err [code] message` statement is the failure shorthand (code
defaults to 500). Inside a `-> result` function these build `result` values.
Inside a route they build HTTP responses.

Because `ok` after `return` is the shorthand, bind first when returning a
call-built value: `val r = ok(41)` and then `return r`, not `return ok(41)`
directly.

`return ok` carries success and `err` carries failure: a 4xx/5xx status through
`ok` is rejected at check time (use `err` for failures), and `err` with a
2xx/3xx status is rejected the same way. An `ok` body must be a string or an
object outside `-> result` functions. An `err` body must be a string.

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

A `result` is an ordinary value: it can be bound to a `val`, with or without an
annotation, and passed to a function as an argument.

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

Routes declare an HTTP method and a literal path. The responses use the
statement forms of the [result grammar](#result-values): `return ok` carries
success and a bare `err` carries failure, with the same status rules.

```orbit
route GET "/health" {
    return ok { status: "ok" }
}

route GET "/files" {
    return ok { files: [{ name: "welcome.txt", size: 29 }, { name: "notes.txt", size: 41 }] }
}

route GET "/private" {
    err 401 "unauthorized"
}
```

A raw string is still the form for an error body or a payload that is
mostly static text (`err 401 """{"error":"pass ?name="}"""`). Objects are
the canonical form for success bodies. Every value inside is escaped on the
way out, which a hand-written JSON string cannot promise.

HTML answers keep the same `return` form through an extern binding, not a
new keyword: `ok` always sends `application/json`, so a page needs the
`text/html` wrapper explicitly.

```orbit
extern fn orbit_response_html(status: int, body: string) -> Response

route GET "/" {
    return orbit_response_html(200, "<h1>hi</h1>")
}
```

The body is sent as-is (no escaping, no JSON encoding). A page built from
user input must escape it first.

Path segments starting with `:` or wrapped in `{...}` capture one
non-empty segment, readable with `req.param("name")`. `*` matches one
segment without capturing. A trailing `:name...` segment captures the
non-empty rest of the path, slashes included, under `name`
(`route GET "/files/:path..."` then `req.param("path")` answers `"a/b/c"`
for `/files/a/b/c`). Dispatch order is static, then single-segment, then
multi: a static route always wins over a param pattern covering the same
path, and `:id` still wins over `:path...` on one-segment requests. The
multi must end the path and name a name — anything else is a check error,
and an empty remainder never matches. Captured values are
percent-decoded by `req.param`. A trailing slash is tolerated.

```orbit
route GET "/notes/:id" {
    val id = req.param("id")
    return ok { note: id }
}
```

Routes can carry a per-route rate annotation after the path, before the body:

```orbit
route GET "/heavy" limit 100/min burst 20 {
    return ok { status: "ok" }
}
```

`limit` takes a positive integer rate plus an optional `/unit` window:
`min` is 60000 ms, `sec` and `s` are 1000 ms, `ms` is 1 ms. With no
`/unit` the window is 1000 ms. `burst` is optional and sets the bucket
capacity. When omitted (or zero) it defaults to the rate. The compiler
rejects a `limit` whose rate is not `> 0`, whose window is not `> 0`, or
whose burst is negative. Routes without `limit` fall back to the global
gate only (see `docs/KYNX.md`). The runtime keeps at most 32 annotated
routes. A further annotation is dropped at startup, while a repeated identical
annotation is idempotent.

The runtime includes HTTP, authentication, JWT, crypto, file, and server support.
Their API is under active development. Check the runtime and examples
before depending on a new helper in a public service.

## SQLite

Orbit links SQLite through its runtime. Models provide schema metadata and the
runtime exposes database operations to generated programs. SQLite is usable for
embedded service storage, but migrations, transaction boundaries, backups, and
input validation remain application responsibilities. Do not build SQL strings
from untrusted input. Prefer the parameterized runtime operations where available.

Every model maps to one table (lowercase plural: `Note` → `notes`,
`string`→`TEXT`, `int`/`bool`→`INTEGER`, `float`→`REAL`, an `id` field is
the primary key) and carries these static methods:

| Method | Returns | Notes |
|---|---|---|
| `M.all()` | JSON array string | full scan |
| `M.order(col)` / `M.order_desc(col)` | JSON array string | whole-table scan by a validated column; anything else answers `[]` |
| `M.where(cond)` | JSON array string | `cond` is a condition over the model's columns, see below; `[]` when refused |
| `M.where(cond, p1..pn)` | JSON array string | one `?` per param, bound in order with `sqlite3_bind_text` |
| `M.find(id)` | JSON object string | single row by key; `""` when missing (`== ""` is the miss check) |
| `M.first()` | JSON object string | first row, `LIMIT 1`; `""` on an empty table |
| `M.count()` / `M.count(cond, p...)` | `int` | `COUNT(*)` without fetching rows |
| `M.create(json)` | `bool` | false on duplicate id or unusable payload |
| `M.update(id, json)` | `bool` | partial: only present keys are written, `id` never; false when no row changed |
| `M.delete(id)` | `bool` | true only when a row was removed |

### Filter conditions

`M.where(cond, p...)` and `M.count(cond, p...)` build `SELECT ... FROM <table> WHERE <cond>`.
Values reach SQLite only through `sqlite3_bind_text`; none is pasted into the
statement text, so a value such as `' OR 1=1 --` is compared as bytes.

`cond` is code, so the runtime holds it to a boolean expression over the model's
own columns. A condition is refused when it:

- contains `'`, `"`, a backtick or `[` (a literal is a value: write `?` and pass it);
- contains `;`, `--` or `/*`;
- has a placeholder count different from the number of parameters, or a named
  placeholder (`?1`, `:x`, `@x`, `$x`);
- names a column the model does not have (SQLite reports it, and the quote rule
  stops a misspelt `"column"` from being read as a string);
- reads another table, `sqlite_master` or a recursive CTE (an authorizer limits
  the statement to `SELECT` on the model's own table), or is not one read-only statement.

A refused query writes `orbit: db: query on '<table>' refused: <reason>` to stderr
and answers `[]` (`0` for `count`). The table name is always the model's own and is
checked to be `[A-Za-z0-9_]+`. `order`/`order_desc` take a column name checked by the
same rule. Do not build `cond` from request data: `doctor` rule `D025` flags that flow.

Reads answer JSON strings, not typed model values. `count` answers `int`.
Indexes ride `migrations "CREATE INDEX ..."` lines (see
`docs/guides/migrations.md`). There are no joins, no `ORDER BY`/`LIMIT`
modifiers, and no transactions: one writer per file.

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

## Standard library: test, strings and hashing

Shipped modules are exercised under `tests/std/` (run with
`test_suite.py --dir tests/std`). Each module's header is the API reference.
Only the scope is listed here:

- `std/test/assert.orb`: assertions for exit-code tests.
- `std/string/string.orb`: byte-wise, ASCII-only string helpers. The checked
  conversions answer `result`, consumed with inline try.
- `std/hash/hash.orb`: SHA-256 and HMAC bindings from the runtime.

`result` is a **builtin type**, not a std module. `ok` and `err` are keywords
and need no import. There is no `std/core/result.orb` to import.

## Standard library: collections, files, IO, time and logging

- `std/collections/lists.orb`: safe accessors and searches over builtin lists.
  Every helper declares its payload (`list<string>`, `list<int>`, …). A caller
  that names the element type and passes a different one fails `orbit check`
  with E1005 naming both. A caller handing a bare `list` still compiles, and a
  mistyped read fails at runtime with a type mismatch instead of a misread.
- `std/fs/file.orb`: path-based reads, writes, existence, removal, and
  directory listing. No open handles, no buffered streams. Append is
  read-modify-write, never atomic.
- `std/io/io.orb`: color-capability queries (`NO_COLOR`/`TERM=dumb` honored)
  with styling in `std/sys/term/color.orb`. No `readLine`, no `eprint`, no
  `println` (builtin `print` already newlines).
- `std/time/time.orb`: second-resolution clock reads. No wall clock, no sleep,
  no sub-second units. Its counter is the same one the builtin
  `system.uptime()` reads: one clock, not two.
- `std/sys/proc/process.orb`: process identity, environment lookup, command
  status, and process exit.
- `std/log/log.orb`: leveled logging with the request context passed
  explicitly. No globals.
- `std/json/json.orb`: JSON-escaping helper for hand-built bodies via
  interpolation. Object literals already escape on serialization. This is for
  the interpolation case, which does not.

## Standard library: cryptography and bytes

- `std/sys/crypto/jwt.orb`: HS256 signing and verification only (no
  `alg:none`). Time travels explicitly as `nowUnix` because Orbit has no wall
  clock. `exp` is required. `nbf`, when present, must not be future. `iat` is
  carried, not enforced. Its SHA-256/HMAC bindings are shared with
  `std/hash/hash.orb`. Redeclaring them in an importer collides on merge.
- `std/bytes/bytes.orb`: byte buffers with decimal length framing. Bytes are
  1-255 (C strings cannot hold NUL). Out-of-range reads answer -1. Shared C
  externs live in `std/string/string.orb`. Redeclaring them in another module
  collides on merge.
- `std/sys/bytes/bitwise.orb`: the bitwise and shift operators as functions,
  for a call site that wants a symbol instead of an operator. The semantics are
  the operators' ([above](#bitwise-and-shift-operators)): five-bit shift
  masking included.
- Not present: raw sockets (there is no socket API in the language or the
  runtime) and a thread pool (needs closures). `std/sys/http/client.orb` is a
  minimal blocking GET -- no TLS, no redirect following, no auth, no proxy.

## `std/quarantine/`: specified, not implemented

Needed-but-missing pieces are written down as
`std/quarantine/*.orb.quarantined` rather than shipped as working-looking
modules. The convention is documented in `std/quarantine/README.md`: `.orb`
means loadable source, so a file the parser cannot read must not carry that
extension.

| module | missing |
|---|---|
| `option.orb.quarantined` | a generic tagged union: `union` takes no type parameter list, nothing infers the argument at construction, and the variant registry is flat by variant name, so two instances would collide. A generic `model` is not the pattern to copy -- it monomorphises today |

`bitwise` left this table: its missing feature (the operators) landed, so
what remained was a syntax slip (`val` as a parameter name) and a missing
test, and both are done. It is `std/sys/bytes/bitwise.orb` again and
`tests/std/test_bitwise.orb` covers the vectors its header published.

Nothing imports the remaining file. Its header names the exact language
feature that would let it land.

## System telemetry

`system.*` calls read live runtime counters:

| Call | Returns |
|---|---|
| `system.uptime()` | `int` seconds since process start |
| `system.pid()` | `int` process id |
| `system.active_workers()` | `int` workers configured at startup (`0` outside servers) |
| `system.http_requests_total()` | `int` completed requests |
| `system.latency_avg_us()` | `int` mean latency, microseconds (`0` before the first request) |
| `system.latency_p50_us()` | `int` median latency, microseconds (`0` before the first request) |
| `system.latency_p95_us()` | `int` 95th percentile latency, microseconds (`0` before the first request) |
| `system.latency_p99_us()` | `int` 99th percentile latency, microseconds (`0` before the first request) |

Latencies are approximate: a percentile is a histogram bucket boundary, not a
measurement of one request.

## Cost ledger

Every server records per-route handler cost automatically - no annotations.
`/_ledger` serves a live table (loopback only), `/_ledger/data` the same as
JSON. Columns: requests, mean ms, p50/p95/p99 µs, DB share, energy, source.
Percentiles are approximate bucket boundaries. The energy column is estimated
(see `docs/ENERGY.md`). Paths starting with `/_` are reserved for
runtime endpoints. Do not define routes there.

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

## Appendix: where detail lives

This reference states current behavior only. History lives in git. The value
model is described in [ARCHITECTURE.md](ARCHITECTURE.md), measured gaps in
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md), module APIs in the `std/`
headers (exercised under `tests/std/`), and command details in
[COMMANDS.md](COMMANDS.md).
