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
  join two branch types into. The IR verifier rejects a value from the other
  branch that does not fit. `val x = if false { 1 } else { "s" }` fails
  `orbit check` and prints
  `orbit check: type verification: copy of 'string' into 'int' in fn '<name>'`.
  Keep both branches the same type.
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
[known limitations](internals/LIMITATIONS_LOG.md).

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

Inside a `-> result` function, `ok(v)` is compared with the payload the
signature declares: `fn f() -> result<string>` refuses `return ok(5)` with
E1006, and a bare `-> result` takes its payload from the `ok` value or from
the result it returns. `tests/negative/n132_result_ok_payload_mismatch.orb`
and `n133_result_composed_payload.orb` pin the refusals;
`tests/suite/result_payload_composition.orb` pins the read that now works.

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
gate only (see `docs/ADMISSION.md`). The runtime keeps at most 32 annotated
routes. A further annotation is dropped at startup, while a repeated identical
annotation is idempotent.

### Request limits

The parser checks the raw bytes before it allocates anything from the request
arena, so a hostile request costs the server only the bytes it already read.
A request over a limit is answered and the connection closes.

| Limit | Default | Environment variable | Answer |
|---|---|---|---|
| Request line | 8192 bytes | `ORBIT_HTTP_MAX_REQUEST_LINE` | `414 URI Too Long` |
| All header lines | 65536 bytes | `ORBIT_HTTP_MAX_HEADER_BYTES` | `431 Request Header Fields Too Large` |
| Header lines | 100 | `ORBIT_HTTP_MAX_HEADERS` | `431 Request Header Fields Too Large` |
| Body (`Content-Length`) | 1048576 bytes | `ORBIT_HTTP_MAX_BODY` | `413 Content Too Large` |

A variable is a decimal integer in `1..2147483648`. Any other value is ignored
with one line on stderr and the default stays. The variables are read once, at
`orbit_http_init`.

The body check uses the `Content-Length` header alone: an over-limit body is
refused before any of it is read. A `Content-Length` that has no digits, is
negative, or appears twice with different values answers `400 Malformed
Content-Length`, because the body boundary is then ambiguous. `Transfer-Encoding:
chunked` answers `501`.

The server reads each connection into a 16 KiB buffer. Until that buffer grows,
a request larger than 16383 bytes in total never arrives whole whatever the
limits say, and the answer is `431` when the header block is still open and
`413` when only the body is.

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

**Read [Imports and visibility](#imports-and-visibility) before you publish
one.** The import namespace is global, a name may be declared only once across
the whole import graph, and `private` does not restrict anything.

## Standard library: test, strings and hashing

Shipped modules are exercised under `tests/std/` (run with
`corpus_gates.py suite --dir tests/std`). Each module's header is the API reference.
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
- `std/option/option.orb`: the optional value, as `union Option[T]` with
  `Some(T)` and `None`. One instance per type written at a use, so
  `Option<int>` and `Option<string>` are two tag sets with two payload types
  declared from one union. A payload-less `None` that no position writes is
  answered E1006 rather than guessed. `tests/std/test_option.orb` covers the
  positions that write an instance, importing the module from another file.
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
  carried, not enforced. The signature is compared with `orbit_ct_equal`, which
  reads every byte whatever the content, so a forger learns nothing from timing.
  Its SHA-256/HMAC bindings are shared with
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

The directory has been empty since 2026-11-02. Two modules left it.
`bitwise.orb.quarantined` was waiting on the bitwise operators, and what
remained after they landed was a syntax slip (`val` as a parameter name) and a
missing test; it is `std/sys/bytes/bitwise.orb`, and
`tests/std/test_bitwise.orb` covers the vectors its header published.
`option.orb.quarantined` was waiting on a generic tagged union. It is
`std/option/option.orb`: the checker substitutes a type argument into a union
payload, and `tests/std/test_option.orb` covers the positions that write an
instance.

What the language still cannot express is in
[Known Limitations](internals/LIMITATIONS_LOG.md). A module that would need one of those
goes into quarantine, and its header names the feature that has to land first.

## System telemetry

`system.*` calls read live runtime counters:

| Call | Returns |
|---|---|
| `system.uptime()` | `int` seconds since process start |
| `system.pid()` | `int` process id |
| `system.active_workers()` | `int` workers configured at startup (`0` outside servers) |
| `system.http_requests_total()` | `int` completed requests |
| `system.http_requests_ok()` | `int` responses below 400 |
| `system.http_requests_error()` | `int` responses at or above 400 |
| `system.latency_avg_us()` | `int` mean latency, microseconds (`0` before the first request) |
| `system.latency_p50_us()` | `int` median latency, microseconds (`0` before the first request) |
| `system.latency_p95_us()` | `int` 95th percentile latency, microseconds (`0` before the first request) |
| `system.latency_p99_us()` | `int` 99th percentile latency, microseconds (`0` before the first request) |

Latencies are approximate: a percentile is estimated inside the histogram
bucket that holds it, anchored on the mean of the requests in that bucket, so a
bucket holding one request answers that request and a wider bucket answers to
within one rank step.

## Cost ledger

Every server records per-route handler cost automatically - no annotations.
`/_ledger` serves a live table (loopback only), `/_ledger/data` the same as
JSON. Columns: requests, mean ms, p50/p95/p99 µs, DB share, energy, source.
Percentiles are estimated inside the bucket that holds them, anchored on the
mean of the requests that bucket received. The energy column is estimated
(see `docs/internals/ENERGY.md`). Paths starting with `/_` are reserved for
runtime endpoints. Do not define routes there.

## Compiler commands

```sh
orbit build app.orb                # Compile to a native executable
orbit run app.orb                  # Build and run it (servers keep the terminal)
orbit check app.orb                # Parse, typecheck, verify the IR; no code
orbit fmt app.orb                  # Format a file (writes only on success)
orbit doctor [dir]                 # Project checks (--fix writes; see [orbit doctor checks](COMMANDS.md#orbit-doctor-checks))
orbit frontend app.orb             # Emit the typed IR
orbit migrate app.orb              # Apply the program's migrations and exit
orbit cluster ...                  # Single-host orchestration (see CLUSTER.md)
orbit --help                       # Display the command-line help
orbit --version                    # Display the compiler version
```

[COMMANDS.md](COMMANDS.md) is the reference for this list, and the one to keep
current.

`orbit test` and `orbit bootstrap` are not implemented. Calling either prints
`Unknown command: test` or `Unknown command: bootstrap` on stderr and exits 2.
`orbit dev` is implemented, and `orbit build` and `orbit run` take
`--backend=c` or `--backend=native`. See [Command Reference](COMMANDS.md) for
the supported list and exit codes.

## Appendix: where detail lives

This reference states current behavior only. History lives in git. The value
model is described in [ARCHITECTURE.md](ARCHITECTURE.md), measured gaps in
[the limitations log](internals/LIMITATIONS_LOG.md), module APIs in the `std/`
headers (exercised under `tests/std/`), and command details in
[COMMANDS.md](COMMANDS.md).

## Syntax by example

### Bindings

`val` binds once. `var` binds a mutable cell.

```orbit
fn main() -> int {
    val answer = 42
    var total = 0
    var i = 0
    while i < 3 {
        total = total + i
        i = i + 1
    }
    return total + answer
}
```

Integer literals are decimal, `0x` hexadecimal, and `_` is a digit separator
(`1_000_000`). Arithmetic is `+ - * /` and `%`; `&&`, `||`, `!`; comparisons
`< <= > >= == !=`.

### Types

The builtin types are `int` (64-bit), `float`, `string`, `bool`, `list`,
`result`, and `void`. A written `list` names its element -- `list<string>`,
`list<int>` -- and a bare `list` in a signature, a field or an annotation is
refused ([E1012](#e1012---a-written-list-names-its-element)): every read from it
would have no type to answer. The one bare `list` left is the value an empty
literal builds, whose element the first push decides. Annotate when the type is
not inferable:

```orbit
fn classify(n: int) -> string {
    if n < 0 { return "negative" }
    if n == 0 { return "zero" }
    return "positive"
}

fn main() -> int {
    val label: string = classify(7)
    if label == "positive" { return 1 }
    return 0
}
```

`list` is the dynamic array. There is no hash-map module in `std/`: a
`{ key: value }` literal is an object (see the reference), and an object
field cannot hold a map. `map` is a known type name but has no runtime
collection or std module behind it. Use models when the fields are fixed and
objects when they are dynamic.

### Functions

```orbit
fn add(a: int, b: int) -> int {
    return a + b
}

fn main() -> int {
    return add(2, 3)
}
```

Recursion works, and the compiler folds calls to pure functions whose arguments
are constants.

A function declares type parameters in brackets: `fn getOr[T](l: list<T>)`.
Each call site infers them from its arguments and compiles its own instance
(`getOr_int`, `getOr_string`), so one body serves every kind with checking
and code per kind. Two positions fixing one variable to different types
refuse the call. A variable nothing fixes is refused. Bodies check once with
parameters opaque. Constraints (`[T: int]`), generic `main`/`extern`, and
generic methods are refused: inference has nothing to check a constraint
against, entry points and externs have no call site or body to build from.

```orbit
fn getOr[T](l: list < T >, i: int, dflt: T) -> T {
    if i < 0 { return dflt }
    if i >= l.len() { return dflt }
    return l.get(i)
}
```

A bare function name in value position is the function as a value:
`val f = add` binds `f` to `add`'s signature, and `f(2, 3)` calls through
it with the same arity and argument checking as a direct call. There is no
capture: a value only ever names a function this module emits, never a lambda,
and there is no `fn` annotation to pass one as a parameter or return one. A
generic function has no one signature until a call fixes its parameters, so
only calling it is allowed. `main` is the entry point, not a value. An
`extern fn` takes no arena, so it is called directly rather than through a
value.

The request arena travels as the first parameter of every emitted C function
and never appears in an Orbit signature, so it changes no arity above. `arena`
is the one name that parameter takes, so declaring a value of that name is
refused: `fn helper(arena: int)` and `val arena = 7` are both errors, and the
diagnostic says which name to pick instead.

```orbit
fn inc(x: int) -> int {
    return x + 1
}

fn main() -> int {
    val f = inc
    return f(1)
}
```

### Errors: `result` and `try` / `catch`

A function that can fail returns `result`. The caller handles it with `try` and
`catch`. There are no exceptions and nothing unwinds implicitly.

```orbit
fn parse(text: string) -> result {
    if text == "" {
        val bad: result = err("empty input", 1)
        return bad
    }
    val good: result = ok(7)
    return good
}

fn read_value(text: string) -> int {
    val value: int = try parse(text) catch {
        return 0
    }
    return value
}

fn main() -> int {
    return read_value("")
}
```

`ok(v)` carries a value, `err(message, code)` carries a diagnostic. Bind the
result to a `val` and return that: a bare `return ok(...)` inside a function
returning `result` is read as a route response, not as a value.

`catch` may bind the error as `e`, which is how you read its message. Adding a
second reader to the program above, in the same file:

```orbit
fn read_error() -> int {
    val value: int = try parse("") catch e {
        return e.len()
    }
    return value
}
```

If a `catch` block does not `return`, execution continues after the `try`.

One naming hazard: a function called `read`, `write`, `open` or `close`
collides with the C library declaration of the same name, and the link fails
even though `orbit check` passes. Name around the platform.

### Models

`model` declares a record with typed fields, and the name doubles as the
constructor.

```orbit
model Rect {
    width: int
    height: int
}

fn main() -> int {
    val r = Rect(3, 4)
    return r.width + r.height
}
```

Models also get `Model.all()`, `Model.where(...)`, `Model.find(...)`,
`Model.create(...)` and `Model.delete(...)` against the database layer.

### Unions and enums

An `enum` declares named integer constants. A `union` declares tagged
variants, each holding a payload type in parentheses.

```orbit
enum Color {
    Red
    Green
}

union Payload {
    Number(int)
    Text(string)
}
```

A variant declares a tuple of payloads: `Both(int, string)` constructs
with one argument per payload in order (`Pair.Both(1, "a")`) and destructures
with one binding per payload (`Pair.Both(n, s) => ...`). A payload can be
any named type, including a model. Arity and payload types are checked
(both directions: construction and patterns).

A `union` takes type parameters too, and every type written at a use names one
instance of it:

```orbit
union Option[T] {
    Some(T)
    None
}

fn describe(o: Option < int >) -> int {
    match o {
        Option.Some(n) => { return n }
        Option.None => { return 0 }
    }
    return 0
}
```

`Option<int>` and `Option<string>` are two tag sets with two payload types,
declared from one union. The argument comes from a position that writes a type:
a parameter's declared type, a binding's annotation, a `return` in a function
whose result is declared, a call argument against its parameter, or the payload
a construction hands over. `val x = Option.None` is refused with `E1006`: the
variant carries nothing, so no value names an instance, and the emitted tag
constant (`Option_int_TAG_None`) is named after one.

`match` dispatches on a union variant.

### Control flow

`if` / `else`, `while` and `for … in` with `break` and `continue`, and
`match` for tagged values.

```orbit
fn main() -> int {
    var n = 0
    while true {
        n = n + 1
        if n > 4 { break }
        if n == 2 { continue }
    }
    return n
}
```

### HTTP routes

A program that serves HTTP declares routes at the top level and calls the
runtime with the server.

```orbit
route GET "/health" {
    return ok 200 "alive"
}

route GET "/greet/:name" {
    val who = req.param("name")
    return ok 200 "hello " + who
}
```

That is the whole program. A file with at least one `route` gets a `main`
generated for it, so you do not write one. The listen port is the file's
`port` declaration (an integer literal in 1..65535, checked by E1008), and
the first command-line argument still overrides it:

```sh
orbit build greet.orb -o greet
./greet 8080
```

If you need startup work, add `fn main() -> int`. The generated server calls
it before accepting connections, and its return value becomes the exit code
when it returns.

Route patterns support `:name` and `{name}` parameters. `req` exposes
`req.query`, `req.body` (`req.json` is the same body), `req.param`,
`req.header`, `req.bearer_token`, `req.role`, `req.has_role` and
`req.file(field, dir)` for multipart uploads. Responses are
`ok <status> <body>` or `err <code> <message>`.

Inside a route, `res` stages response headers: `res.header(name, value)`
and `res.cookie(name, value)` (which sends `Set-Cookie` with `Path=/`).
Staged lines flush onto the returned response, so redirects are an
ordinary `ok` with a `Location`:

```orbit
route GET "/old" {
    res.header("Location", "/new")
    return ok 302 "moved"
}
```

A name with a colon, or a name or value carrying CR or LF, is refused:
a value smuggling CRLF would split a second header into the reply.
`ok` accepts any 2xx or 3xx status. 4xx/5xx belong to `err`, which
refuses 2xx/3xx in turn.

Route annotations control admission: `route GET "/x" limit 20 / s burst 20`
sets a per-source-IP budget, enforced by the admission gate. See [admission](ADMISSION.md).

### Imports

```orbit
import "std/string/string.orb"
import "std/test/assert.orb"
```

Paths are relative to the importing file or to the standard library, so the
two spellings above both resolve from anywhere in the tree. The standard
library lives in [`std/`](../std). `std/test/assert.orb` provides the assertion
helpers the suite uses.

### Comments

`//` to end of line. Block comments are not part of the language.

## Memory

Orbit allocates from arenas, not from a general heap. An arena reserves
64 MB of address space, commits pages as its bump cursor advances, and frees
everything at once by resetting the region. There is no per-object free and no
tracing collector. `std/sys/arena.orb` exposes the epoch API; the layout and
its measurements are in [internals/ARENA.md](internals/ARENA.md).

## Imports and visibility

### The rules

1. **One flat global namespace.** Every function, model, enum, const and type
   in every transitively imported file shares one namespace. There is no
   prefixing, no aliasing, and no scoping of imports.
2. **A name may be declared once across the whole import graph.** Two modules
   that declare the same name is a hard error, not a shadow.
3. **`private` does not restrict anything at an import boundary.** It is
   accepted on `fn` and ignored. On a `type` it is a parse error.
4. **Imports are by path.** Relative paths resolve against the importing
   file. `std/...` and `lib/...` resolve against three fixed roots.
5. **A library cannot declare its dependencies.** There is nothing to
   declare them in.

### 1. The namespace is flat and collisions are fatal

This is the rule that will actually stop you. Two modules, one name:

```orbit
// a.orb
fn helper() -> int { return 1 }
```

```orbit
// b.orb
fn helper() -> int { return 2 }
```

```orbit
// main.orb
import "a.orb"
import "b.orb"
fn main() -> int { return 0 }
```

```console
$ orbit check main.orb
Semantic error: Duplicate symbol: helper
$ echo $?
1
```

`declareSymbol` walks the current scope and reports `Duplicate symbol: <name>`
the moment it sees a second one (`compiler/front/sema.orb:1428`).
The check is on the symbol's name alone - no module, no origin, no overload. It
does not matter which file is imported first, and it fires even if the two
functions have different signatures.

**What to do about it.** Prefix every public name with your library's name.
`json_parse`, `jwt_sign`, `term_color` - not `parse`, `sign`, `color`. There
is no way around this and the compiler will not warn you in advance, so the
prefix is on you.

Two things follow from the flatness that are worth knowing:

- **A transitive import is a real dependency.** If your library imports
  `std/string/string.orb`, anything that imports your library also gets
  whatever that module declares, and can collide with its own names.
- **A dead import is not free.** Nothing tree-shakes and nothing is scoped, so
  importing a module for one function brings all of its names in - and all of
  its code. I declared three functions in a module, called one of them, and
  both unused ones were in the generated C.

### 2. `private` is decorative

```orbit
// q.orb
private fn secret() -> int { return 42 }
```

```orbit
// r.orb
import "q.orb"
fn main() -> int { print(secret())  return 0 }
```

```console
$ orbit check r.orb
Checked r.orb: no errors.
```

`private` is consumed by the parser and then never consulted again. On a
function it is accepted and dropped. On a type declaration it is rejected
outright:

```console
$ orbit check s.orb        # private type Foo { a: int }
Parser error at line 1: 'private' is not supported on types yet.
```

So there is no way to write a module with a private helper. Either accept that
every name in your file is public, or keep helpers in a file that nothing
imports.

### 3. What is a module, physically

A module is one `.orb` file. The resolver flattens every transitively
imported file into a single AST (`compiler/front/resolver.orb`), so "module" means
"a file you import", not "a unit of encapsulation" - there is no encapsulation
at all.

Relative imports resolve against **the importing file**, not the working
directory, so they work from anywhere:

```orbit
// app.orb
import "./lib/http/util.orb"
```

```console
$ cd /somewhere/else && orbit check /path/to/app.orb
Checked /path/to/app.orb: no errors.
```

Nested relative imports work the same way: a module at `lib/http/mid.orb`
importing `"./util.orb"` finds `lib/http/util.orb`. Verified.

There is no `use` with an alias - `use "a.orb"` is a parse error
(`Expected module name`). And there is no manifest: I looked for an
`orbit.mod`, an `orbit.toml` or anything the resolver reads, and there is none.
Dependencies are implicit in the import lines and nothing validates them
except the compiler failing to read a file.

### 4. `std/` resolves against three roots, and that is the install trap

A `std/...` or `lib/...` import is looked up in exactly this order
(`resolveStdPath`, `compiler/front/resolver.orb:69-90`):

1. the **compiler binary's own directory**,
2. that directory's **parent**,
3. the **current working directory**.

Nothing else. No environment variable, no search path you can set, no
`ORBIT_STD` escape hatch.

**Consequence: a released compiler cannot import `std/`.** The release ships
three things - the platform binary, `orbit_bootstrap.c`, and the seed
artifacts. There is no `std/` in it (see [Release Artifacts](../CONTRIBUTING.md#releases)), and
no installation step puts one next to the binary. So this is the state of a
freshly downloaded compiler:

```console
$ cd /tmp                       # a directory with no std/
$ orbit check prog.orb          # prog.orb: import "std/string/string.orb"
Import error: Could not read imported module: std/string/string.orb
$ echo $?
1
```

The same program, run from a directory that happens to have a `std/`, works:

```console
$ cd /path/to/orbit-lang
$ orbit check /tmp/prog.orb
Checked /tmp/prog.orb: no errors.
```

This is why every gate in the repository runs from the repository root, and
why it has never been caught: in CI the working directory always contains
`std/`, so the third root always answers. **The failure only appears for a user
who installed the compiler, which is exactly the person who is not in CI.**

The workaround today is to put a copy of `std/` beside the binary or beside its
parent, or to run from a directory that has one. If you are shipping the
compiler yourself, do that as an explicit install step and say so.

There is a second, smaller version of the same assumption in the build step:
`orbit build` invokes the C compiler with the literal relative include path
`-I"runtime"`, so the **working directory** also has to contain a `runtime/`
directory. A program that compiles in the repository root fails elsewhere with
`fatal error: socket_compat.h: No such file or directory`. Same family, same
cause, same reason no gate sees it.

### 5. How to write a library, then

Given all of that, a library that other people can actually import looks like
this:

- **Prefix every declaration** with the library's short name. This is the only
  defence against rule 1.
- **Keep the file self-contained.** Import only what you use, and prefer
  `std/` over `lib/` - both resolve the same way, but `std/` is the tree the
  gates exercise.
- **Do not rely on `private`.** If a helper must not be part of your
  public names, put it in a file you never import, or name it so nobody will.
- **Document the expected layout** next to your library: which `std/` copy the
  importer needs and where. Today that is the whole install story.
- **State your compiler version.** There is no compatibility range machinery
  (see [Versioning](SUPPORTED.md#versions-and-compatibility)), so pin the release you were written
  against. `orbit --version` exists and is the thing to check.

A worked example, deliberately boring:

```orbit
// jsonpath/text.orb
//
// Every public name carries the jsonpath_ prefix: the import namespace is
// global and a bare `text` would collide with anything.

fn jsonpath_text_len(s: string) -> int {
    return s.len()
}

fn jsonpath_text_prefixed(s: string) -> bool {
    return s.len() >= 0
}
```

The prefix is not a style preference. It is the difference between a library
that imports and one that produces `Duplicate symbol: text`.

## Diagnostics

### E1000 — frontend re-emit of a parser diagnostic

Fires in `compiler/tir/entry.orb`, `appendParserDiagnostics`: every
parser diagnostic is re-emitted into the TIR module with code E1000,
keeping the parser's original message text. This is the `orbit frontend`
command, not `orbit check` (which renders the parser's own E0301–E0304
cards). Fix hint: read the message text — it is the underlying parser
diagnostic. No negative case: the frontend gate (`scripts/corpus_gates.py frontend`)
covers this path.

### E0130 — nesting too deep

Fires in `compiler/front/parser.orb`, `parseDepthGuard`: expression or statement
nesting past depth 600. Fix hint: break the expression into named
intermediate values. No negative case pins it.

### E0301 — unexpected token

Fires in `compiler/front/parser.orb`, `parserUnexpectedToken`, and the object-literal
`{` fallback (`parseObjectLiteralFallback`). Fix hint, from
`compiler/host/pipeline.orb`, `parserDiagnosticHint`: check for missing brackets,
quotes, or keywords before the flagged token. Note: the recovery cases
`n19`/`n20` assert the *uncoded* `parserError` messages (`Parser error`,
`Expected '}' after block.`), not this code.

### E0302 — `if` used as a value needs `else`

Fires in `compiler/front/parser.orb`, `parseIf` when `wantValue` holds and no
`else` follows. Fix hint: give the `if` an `else` branch, or use it as a
statement. Pinned by `tests/negative/n43_if_value_without_else.orb`.

### E0303 — `if` has no then branch

Fires in `compiler/front/parser.orb` when `else` arrives with no then branch
before it. Fix hint, from `parserDiagnosticHint`: a branch beginning with
an operator needs `then` before it, as in `if n then -1 else 0`. No
negative case pins it today.

### E0304 — `if` branch must be a single expression

Fires in `compiler/front/parser.orb`, `parseIfBranch`, when a braceless branch
starts with a statement-only token. Fix hint: wrap statement branches in
`{ ... }`. Pinned by
`tests/negative/n44_if_branch_is_a_statement.orb`.

### E1001 — non-exhaustive match

Fires in `compiler/front/sema.orb`, `reportErrorAt` from the match-exhaustiveness
check. Fix hint: add a case for every variant, or a `_` arm if the
fall-through is intended. Pinned by `tests/negative/n01_union_missing_arm.orb`,
`n23_union_enum_missing_arm.orb`, `n24_union_match_in_expression.orb`, and
`n25_union_wrong_qualifier.orb`.

### E1002 — literal index out of range

Fires in `compiler/front/sema.orb` when a literal index into a literal string or
list receiver is past the end. Fix hint: indices run `0` to `len - 1` here.
Guard a computed index with `if i < xs.len()`. Pinned by
`tests/negative/n32_at_out_of_range.orb`.

### E1003 — bad member read, bad construction, bad print arity

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for a model built with the
wrong spelling or arity (`Model { field: value }` literal form, one argument
per field). It also fires for a field or variant read that nothing declares
(`Model 'Point' has no field ...`, `'int' has no member ...`,
`'Shape' has no variant ...`), for a member call whose name the receiver's
member set does not contain (`'list<int>' has no member 'sort'`,
`'list<int>' has no member 'indexOf'`), and for `print` called with anything
but exactly 1 argument. Fix
hint is per site (each `reportErrorAt` call carries its hint; the member-call
diagnostic is the one under `checkNode`'s `ASTNode.MemberAccess` callee arm):
spell the member as declared, construct with one
argument per field in order, print one value. Pinned by `n05`, `n06`, `n13`,
`n14`, `n15`, `n47`, `n57`, `n66`, `n68`, `n78`, `n111`, `n112`, `n113`-`n115`
and `n116` (`n66`:
variant arity at construction; `n68`: pattern binding count in `match`; `n78`:
`res.header`/`res.cookie` take exactly 2; `n111`: a member call with no
lowering; `n112`: a local named `system` shadows the builtin, so the member is
diagnosed against the local's type; `n113`-`n115`: a member another receiver
answers, on a list, a string and a map; `n116`: a declared function named like
a lowered member does not answer the member call). `n126` is the union case read
against a binding's annotation: `val x: Option<int> = Option.Some()` resolves
`Option_int` from the annotation, so what refuses it is the payload count. The same code covers `ok` and `err` built
with the wrong number of positions: `ok` takes exactly one value, and `err`
takes a message and an optional code, which is the grammar in
`docs/LANGUAGE_REFERENCE.md`. Before that check both answered `result` before
their argument count was looked at.
Pinned by `tests/negative/n97_result_no_value.orb` (`ok()`). The locations in this
section name functions, because every edit to `sema.orb` moves a line number.

### E1004 — literal zero divisor, `INT_MIN / -1`

Fires in `compiler/front/sema.orb` for a statically decidable bad division: a
literal `0` divisor, or dividing the most negative int by `-1` (which
overflows and faults the same way). Fix hint: guard with `if d != 0`, or
divide as floats. Pinned by
`tests/negative/n41_division_by_zero_is_not_a_diagnostic.orb`. A zero held
in a variable still reaches the hardware — that half is not done (see the
case header).

### E1005 — call argument type mismatch

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

### E1006 — bad type name or binding mismatch

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for a pushed value that
contradicts the list's element type. It also fires for a type name nothing
declares (types are lower case, or declared with `model`/`union`), and for a
binding whose value contradicts its annotation. Also a bare generic model in a
signature (`Box` with no argument — write `Box<int>`), an undeterminable
generic type parameter (`n52`), a generic field fixed to one type by an
earlier field (`n50`), and a payload-less union variant that no position writes
(`n118`: `Option.None` carries nothing, so the argument has to come from a
parameter's declared type, a binding's annotation, a declared `return` or a call
argument). `checkVarDecl` resolves the annotation before it reads the value,
which is what makes the annotation one of those positions:
`val o: Option<int> = Option.None` -- the form this code's own help text names --
checks clean, and `val x: Option<int> = Option.Some()` is read against
`Option_int` and refused by the payload count instead (E1003, `n126`). The last two point at the enclosing declaration:
object literals carry no parser position, so `checkGenericModelFields` reports
against the declaration site stamped by `checkVarDecl`/`checkConstDecl`
(`valueSite`). A literal returned directly keeps the one-line form until
literal positions exist. The `n118` refusal points at the member read itself
(`ma.line`, `ma.col` in the `ASTNode.MemberAccess` arm of `checkNode`):
`Option.None` is a value position, and the rule needs the type the program
wrote, not the union's declaration. The construction site prints the other
sentence: `unionInstanceForConstruction` reports it, reached from the `Call` arm
of `checkNode`. `n124` pins it with `val x = Option.Some()`: `Some` declares a
payload, so the read site stays silent, and the empty argument list decides no
instantiation. A call that reads a template member and constructs from it is
decided in one place: `calleeIsTemplateConstruction` answers the construction,
and the `Call` arm does not read that member as a value first. So
`val x = Option.None()` prints one E1006 block, the construction sentence, exit
1 (measured 2026-11-03 with the fixed point). `n124` pins that sentence and
`n125` pins the count, with its header's `one-diagnostic:`. The cites in this
section name functions, because every edit to `sema.orb` moves a line number.
Fix hint: change the value or the
annotation. Write the type arguments. Pinned by `n11`, `n30`, `n48`, `n49`,
`n50`, `n51`, `n52`, `n118`, and `n70` (`n70`: a generic function's parameter no
argument can fix).

### E1007 — bad top-level declaration

Fires in `compiler/front/sema.orb`, `reportErrorAt`, for `var` at file scope and
for a top-level `val` whose value is not an int or bool literal (only
literals become a `#define`). Fix hint: put state inside functions.
Pinned by `tests/negative/n45_top_level_var.orb`, which pins the code
itself.

### E1008 — bad `port` config declaration

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

### E1009 — bad assignment target

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

### E1010 - a `result` value is discarded

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
kind (a bare name, an `if` used as a statement) has no position in the AST and
prints the one-line form without the code. Pinned by
`tests/negative/n98_result_discarded.orb`.

### E1011 - variant name belongs to more than one union

Fires in `compiler/front/sema.orb`, `checkVariantCall`, for a construction that
names a variant and no owner when two unions declare that name. The registry is
keyed on the variant, so the first row would answer for both: one of the two
constructions was wrong, and nothing said which. `checkNode` takes no expected
type, so a bare `Body(3)` has no owner to read. Fix hint: write the union --
`Packet.Body(3)`. A `match` arm needs no owner, because the scrutinee's type is
one. The message names every union that declares the name. Pinned by
`tests/negative/n121_bare_ambiguous_variant_is_refused.orb`.

Payloads and arity are read from the owner the program wrote, so `E1005` and
`E1003` describe the union the construction names rather than whichever was
declared first.

### E1012 - a written list names its element

Fires in `compiler/front/parser.orb`, `parseTypeName`, for a `list` or `List`
written without `<...>` as a type: a parameter, a return type, a model field or
an annotation. Nothing downstream could say what a read from it yields, so
`xs.get(i)` reported E2005 and the C backend stored a `void*`. Fix hint: write
the element, `list<string>`. A value built from an empty literal keeps a bare
`list`, because nothing wrote its type and the first push decides the element;
that value is not a declaration, and the rule does not fire on it. Pinned by
`tests/negative/n127_list_type_needs_element.orb`.

### E1013 - a value with no elements is indexed

Fires in `compiler/front/sema.orb`, `checkNode`'s `IndexAccess` arm, for `v[i]`
where `v` has a known type that is not a list, a map or a string. The arm
answered `unknown` for every other receiver, so `p[0]` on a model compiled
clean and reached codegen with no kind to lower it. Fix hint: read a model
field by name, and index only the three types that hold elements. A receiver
whose type is `unknown` is left alone, because nothing has typed it yet.
Pinned by `tests/negative/n131_index_a_model_is_not_a_list.orb`.

### E2001 - unknown identifier (frontend)

Fires in `compiler/tir/lower.orb`, `lowerExpression`: a load whose
binding carries no type, or whose name no binding declares. This is the
`orbit frontend` lowering. `orbit
check` rejects the same program through sema's uncoded `Undeclared
identifier` diagnostic (pinned by `n09`). A `val x: T = e` whose value has no
type binds `T` when it is `int`, `float`, `bool`, `string` or a `list<T>`,
because sema already checked the annotation against the value. A list keeps
its element -- `list<DoctorEdit>` stays whole, because a later `.get` answers
from it -- and a binding without the annotation stays untyped. Fix hint: declare the name before
use, or annotate the `val`.

### E2002 — incompatible binary operands (frontend)

Fires in `compiler/tir/lower.orb` when a binary expression's result
type is `unknown`. Frontend lowering only. The unknown-census counts these.
Fix hint: make both operand types agree (or bind them first).

### E2003 — invalid unary operand (frontend)

Fires in `compiler/tir/lower.orb` when a unary expression's result
type is `unknown` (`!` needs `bool`, `-` needs `int`/`float`). Frontend
lowering only. Fix hint: apply the operator to a value of the type it
takes.

### E2004 — untypable member read (frontend)

Fires in `compiler/tir/lower.orb` when a `.field` read cannot be
typed. Added for F-0018: loads, binary ops and unary ops had diagnostics
and member reads had none, so an untypable member reached codegen silently.
Frontend lowering only. Fix hint: read the field off a value whose type the
front end knows.

### E2005 — untypable call result (frontend)

Fires in `compiler/tir/lower.orb` when a call's result type is
`unknown` — a call whose signature the front end does not know.

The message ends with the callee as the source spells it: a name, or `.field`
for a method. The census sorts 621 of them on 2026-11-04 and 566 answer to a
method whose receiver has no type, which is a different fix from a missing
declaration. A call to a function the same file declares is typed from that declaration (`declaredReturnType`), so what fires here is a call into another file or an unknown callee. Same F-0018
origin as E2004, and the larger of the two (unchecked argument types
reached codegen through it). Frontend lowering only. Fix hint: call a
declared function with the declared arity.

### E2100 / E2101 / E2102 — condition and bound types (frontend)

Fire in `compiler/tir/lower.orb` for the `if` (E2100) and `while` (E2101)
conditions whose type is not `bool`. E2102 is the same rule on a bound:
`for x in lo..hi` counts an int, so a bound that is not `int` gets one of the
two messages naming which. The loop binds its item to that counter, so a bound
this pass cannot type would put an `unknown` item in the file. Frontend lowering
only. Fix hint: compare first, branch on the comparison; count between two ints.

### E3000 — top-level declaration cannot be lowered (frontend)

Fires in `compiler/tir/lower.orb`, `lowerProgramToTir`, for a
top-level declaration kind the frontend does not lower. Frontend lowering
only. Fix hint: this is a frontend-coverage gap, not a program typo — file
it with the program attached. It reads 0 on the 2026-11-02 corpus, from 3:
`migrations` lines and a file-scope `config` value declare data and lower to
nothing, the way a file-scope `const` does. A `schedule` stays in this code on
purpose -- its handler is a body, and skipping it would let the pass describe a
file whose code it never read.

### E3001 — expression cannot be lowered (frontend)

Fires in `compiler/tir/lower.orb`, `lowerExpression` fallback, for an
expression kind with no lowering rule, and the message ends with the node
class: `expression cannot be lowered to TIR: Match`. Before the class
was named, the census could report how many times the front end gave up and
not on what. `scripts/measure.py census` prints the tally by class. Frontend
lowering only. Fix hint: same as E3000 — a coverage gap, file it with the
class. 682 hits on the 2026-11-03 corpus, from 9,233 before the classes were
named and read. Fourteen have since stopped firing: an `Empty` statement, because a
statement with no instruction to emit lowers to nothing; `x = 5`, which is the
`bind` a `val` uses; `d.x = 2`, which emits `store_field` when the place's own
value is typed; a bare `return`, which emits `return unit void`; `break` and
`continue` inside a loop, which emit `jump` to the block the loop made for them;
and `for x in 0..n`, which lowers to the `while` shape plus an increment block.
`xs[i] = v` emits `store_index` when the container's own type is one the pass can
read, `Point { x: 0, y: 0 }` emits `construct Point 2 x v0 y v1`, and
`return ok 200 "ready"` emits `result_ok result 200 v0` plus the `return` of it. `try f() catch { ... }` lowers when the callee writes the payload type inside its `result` (`-> result<string>`); the 93 of this corpus write a bare `result`, so they still give up, now naming the type that is missing rather than the node class.
What still fires is a write whose place this pass cannot read -- `cannot lower
this assignment to TIR: MemberAccess`, 212 cases, and the same on an index, 5 --
and an expression the pass has no rule for: `Match` (297), `If` (30),
`ObjectLiteral` (12) and an
index *read*, `xs[i]` (8), whose element type the pass does not keep. A `for`
over a value with no element table (20) and a labelled `for` with no target for
a named `break` (4) say which they are.

### E3002 — frontend expected a program root

Fires in `compiler/tir/lower.orb`, `lowerProgramToTir`, when the root
node is not a program. Frontend lowering only, and unreachable from the normal
pipeline. Fix hint: none — internal invariant.

### C names

The C backend emits every symbol the program defines as `o_<name>`: functions,
route handlers, models, unions, enums, constants and variant constructors. A
user name therefore never meets a name from libc, a platform header or the
runtime, whose exports all start with `orbit_`. `main` is emitted as
`orbit_main` and an `extern fn` keeps its own name. The IR (`--emit-ir`) keeps
the user names.

One name check remains. `compilerCalledRuntimeName` in `compiler/front/sema.orb`
refuses a `fn` named like a runtime function the compiler calls when it lowers
other syntax, such as `orbit_string_slice` for `text.slice(a, b)`. The IR names
a callee by string, so the user function would receive those calls. The negative
case is `n89`; `tests/suite/c_names_user_defined.orb` holds names that must stay
accepted.

### Uncoded rejections (no E-code, still pinned)

These print the one-line `Semantic error:` form and pin a substring:

| message | case |
|---|---|
| `Cannot call 'n': it is a int, not a function` | `n12` |
| `Undeclared function: ...` | `n22`, `n110`, `n117` (`n110`: a provided name with no lowering; `n117`: a member-only name called as a function) |
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
| `'...' is a runtime function the compiler calls itself ...` | `n89` |
| `Parser error` / `Expected '}' after block.` (uncoded recovery) | `n19`, `n20` |

## Formatting

The rules below are the contract for `orbit fmt`: the style the repository already follows, rule by rule, with evidence, and the formatter implements exactly what is written here. The corpus is recursive `*.orb`
under `compiler/` (29 files), `tests/suite/` (129),
`std/` (21) and `tests/std/` (24), plus
`examples/*.orb` (13, minus
`orbit_full_expansion.orb`). 216 files -- the exact list
the fmt gate verifies (`make all` prints `fmt ... (216 files, 8 workers)`). The rules were inferred
from that corpus with strings and comments stripped, so stylish string contents (JSON payloads,
URLs) do not pollute them, and they stay readable as the corpus grows.

### What the formatter is

`orbit fmt` is token-based. It reuses the self-hosted lexer
(`compiler/front/lexer.orb`, `compiler/front/token.orb`), preserves every token, every
string/character literal byte, and every comment, and only rewrites
whitespace: indentation, intra-line spacing, and line breaks. Because the
generated C contains no source line directives and string contents are never
touched, formatting cannot change codegen.

Validation gate: `fmt` accepts exactly what `orbit check` accepts. The input
is parsed, imports are resolved, and the program is typechecked with the same
pipeline (`checkSourceWithFile`). Anything else is reported (same messages as
`check`) and the file is left untouched.

### Commands and exit codes

- `orbit fmt <file.orb>` formats one file. The whole output is built in
  memory and written only on full success. A failure never leaves a partial
  file. Prints `Formatted <path>.`, or `Already formatted <path>.` when no
  change was needed. `--quiet` silences both lines. Single-file mode has
  no `--verbose` output beyond them.
- `orbit fmt --check <file.orb|dir>` prints the paths of files that need
  formatting (one per line, sorted) and exits 1. When everything is
  formatted it prints nothing and exits 0. `--verbose` adds a
  `scanned N files, M need formatting` line. A directory is scanned
  recursively for `*.orb` files. Inputs that fail validation are listed and
  also get the usual diagnostics on stderr.
- `orbit fmt --help` prints usage. Missing arguments or unknown flags print
  usage and exit 2. Operational failures (unreadable file, malformed input,
  unwritable output) exit 1. Success exits 0.

### Style rules

#### 1. Indentation: 4 spaces, recomputed from brace depth

Evidence: every indented line in the corpus uses a multiple of 4 spaces
(0/4/8/12/...); zero tab-indented lines; zero trailing
whitespace lines. Indentation is recomputed from `{` depth, so
mis-indented input is fixed (the corpus itself has a few such lines, e.g.
single-statement `if` bodies that drift, which `fmt` aligns).

Only `{` / `}` change depth. `(` / `[` never span lines in the corpus (zero
lone `)` or `]` lines), so call, index, list-literal, and generic-argument
contents are joined onto one line with single spaces.

#### 2. Braces: same line as the construct, `}` placement preserved

Evidence: every `keyword-or-paren {` same-line opening in the corpus, zero
lone `{` lines.
An opening brace is always joined to the preceding token with one space:
`) {`, `else {`, `=> {`, `name {`, `@auth {`.

- `{}` stays together with no inner space (`_ => {}`, `[]`-style empties).
  Every empty-`{}` site in the corpus is inline. A multi-line empty block
  (`{\n}`) collapses to `{}` (rare, against many inline sites, so the majority
  wins).
- Otherwise the inside of a same-line `{ ... }` block gets one space on
  each side: `{ st.success = false; return false }`.
- A multi-line block puts a newline after `{` (unless the source kept code
  on the brace line, which is preserved, e.g. nested single-line `if`/`else`
  chains). The closing `}` keeps its source line break: newline before
  `}` when the source had one, otherwise ` }` (cascading `} } } }` closers
  are preserved).
- No blank line is ever added or kept directly after `{` or directly before
  `}` (0 occurrences in the corpus).

#### 3. `else` aligns with the block it closes

Evidence: every `} else` / `} else if` same-line closer in the corpus closes
a multi-line block, and every `else` / `else if` line that starts a new line
follows a single-line block. Zero violations either way.

- After a multi-line block: `} else {`, `} else if cond {` (joined even if
  the input split them).
- After a single-line block: newline plus `else` / `else if` at the same
  indent as the `if`:
  ```
  if v.value.indexOf("TAG_") != -1 { inf = getEnumNameFromTag(v.value) }
  else { inf = "string" }
  ```
  An empty `{}` block is the exception: it reads as a unit, so `else` joins
  (`if x {} else { ... }`; no corpus sites, keeps the output a fixed point).
- `catch` always stays attached to its `try` expression with spaces
  (`try make_failure() catch {`; `} catch` never occurs).

#### 4. Spacing inside lines

- Binary operators and `=` get exactly one space on each side: `=`, `==`,
  `!=`, `<`, `<=`, `>`, `>=`, `<<`, `>>`, `+`, `-`, `*`, `/`, `%`, `&&`,
  `||`, `|`, `^`, `->`, `=>`. Evidence: zero unspaced occurrences outside
  strings, for every one of them, `|` union pipes included. The bitwise
  and shift operators occur spaced in `tests/suite/bitwise_operators.orb`.
- Unary `!`, `-` and `~` attach to their operand with no space after
  (`!req.has_role("admin")`, `-(-5)`, `~mask`). Every unary `!` in the
  corpus is written that way. A `-` is unary after an operator, `=`, `(`,
  `[`, `{`, `,`, `;`, `=>`, `->`, `:`, `|`, another `-`/`!`, a keyword, or
  at a statement start. Elsewhere it is binary. `~` has no binary form, so
  it always attaches. (Spacing never affects meaning: the token stream is
  unchanged.)
- `&` is two spellings: the prefix sigil (pointer types, e.g. `: &Foo`)
  attaches with no space after, like `!`, and the binary operator
  (bitwise-and) gets one space on each side. The lookback that decides is
  the unary minus's: after a keyword, an opening delimiter or the start of
  the file it is the sigil. After a value (a word, `)`, `]`, `}`) it is the
  operator. The prefix spelling does not occur in the corpus. The operator
  does, spaced, in `tests/suite/bitwise_operators.orb`.
- `:` has no space before and one space after (`name: type`, `x: int = 3`).
  Zero violations. `::` never occurs.
- `,` has no space before and one space after (`f(a, b)`). No bare comma
  outside strings. A trailing comma directly before `)` / `]` keeps
  no space after it.
- `;` separates same-line statements with one space after
  (`{ a; b }`; every corpus site is mid-line). At block level a newline
  after `;` or `,` is preserved (one per line, as in `enum`/`union`
  variant lists). Inside `(`/`[` contents it is joined with a space (the
  corpus never spans those).
- `.` never takes spaces (`a.b()`, `ports[0]`). Zero spaced occurrences.
- `(`/`)`/`[`/`]` have no inner spaces (`f(a, b)`, `[]`, `()`). `[` attaches
  to the previous token (`ports[0]`; a `return []` site keeps its space
  after the keyword). `(` attaches directly except after a keyword
  (`if (x) {`, `return (x)`), but `ok` and `err`
  are call-like value keywords and attach (`ok(41)`, `err("msg", 7)`), never
  spaced. After operators, `,`, `:`, `=>`, `->`, `{`, or `}` the
  space before `(`/`[` comes from the operator rule (`= (`, `, (`).
- Two adjacent words/literals are separated by one space (`fn main`,
  `route GET "/health"`, `return ok 200 ...`, `val mut total`).
- Conditions keep their source parentheses: bare `if x == y {` and
  parenthesised `if (x) {` are both left as written. Only inner spacing is
  normalised.

#### 5. Blank lines: preserved, at most one, never inserted

Evidence: exactly one blank line separates nearly all top-level
declarations. The exceptions are structural (consecutive `import` lines,
`port`/`cors`/`db`/`env` groups, comment-attached declarations, stacked
single-line models) plus a handful of missing blanks. Stray blanks are rare:
one mid-file double blank, one file missing its final newline, and a few
files with one (or two) extra blank lines at end of file.

- Two or more consecutive blank lines collapse to one.
- No blank line is added after `{`, before `}`, at the start of the file,
  or between declarations. Existing ones (max one) are kept.
- The file ends with exactly one trailing newline (LF). A corpus file that
  lacks it gets one.

#### 6. Line endings, tabs, BOM, comments, strings

- Output uses LF (`\n`) only, matching the committed canonical form (the
  working-tree CRLF comes from `core.autocrlf`). Tabs become indentation
  spaces. Trailing whitespace is stripped. Carriage returns are dropped.
- On Windows checkouts, `.gitattributes` pins `*.orb` to `text eol=lf` so
  fresh clones materialize LF files and `fmt --check` stays quiet. Files
  already materialized as CRLF keep working (status stays clean) but are
  listed by `--check` until re-materialized. Reformatting them once
  converts them to LF.
- A UTF-8 BOM is preserved when present (one suite file relies on BOM
  tolerance). It is never added.
- Comments are preserved verbatim and re-attached by position: same-line
  trailing comments keep one space before `//` (locally aligned ones are
  normalised), own-line comments
  keep their line (indented to the current level). `/* ... */`
  comments in the corpus stay inline. Comment text is never reformatted.
- String, character, integer, and float literal text is emitted byte for
  byte, including `${...}` interpolation and escapes. The formatter never
  wraps long lines (the corpus has lines far past 120 columns, including a
  1000+ column union alias). It never joins or splits string contents.

### Normalise vs leave alone (summary)

Normalised: indent width and consistency, and spacing around every operator /
colon / comma / semicolon / dot / paren / bracket / brace / arrow. This covers
`(`/`[` joining, `{` joining, `else` placement after `}` (rule 3) and the
trailing-comment gap (one space). It also covers blank-line collapsing,
leading/trailing blank stripping, CRLF/tabs/trailing whitespace, the single
trailing newline and BOM preservation.

Left alone: the token stream (names, keywords, literals, punctuation choice),
condition parentheses, and statement-per-line layout (single-line blocks stay
single-line, multi-line stay multi-line). Also left alone: blank lines between
declarations (never inserted), long lines (never wrapped), comment and string
contents, and the rarity of the `&` prefix (grammar-derived, no corpus sites).

### Risks

- `compiler/selfhost/stage3.exe.c` (canonical C) goes stale after any
  compiler change by design: refreshing it needs
  `scripts/trust.py build --promote` (a long build).
- `--check <dir>` lists files with `find ... | sort` (POSIX) or
  `cmd /c dir /s /b ... | sort` (Windows) through the same shell-exec
  helper the build driver uses. Paths containing double quotes are not
  supported. An unreadable path (or a directory with no `.orb` files)
  reports `Error: Could not read input path:` with exit 1 rather than
  silently passing.
- The `&` prefix rule and the continuation-line indent have no corpus
  sites. Both follow the grammar and the surrounding rules and are
  documented as such.
