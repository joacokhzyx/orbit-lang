# Orbit syntax guide

A one-page skeleton of the language, with every sample here compiled and run
by the test suite. [Language Reference](LANGUAGE_REFERENCE.md) is the complete
specification with the semantics; this page is the shape of the thing.

New here? [Getting Started](GETTING_STARTED.md) gets you running code first.

## The whole program

```orbit
fn main() -> int {
    return 0
}
```

`fn main() -> int` is the entry point and the return type is `int`. The
process exit code is the return value, which is how the test suite asserts
behaviour. Statements are newline-terminated; there are no semicolons.

## Bindings

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

## Types

The builtin types are `int` (32-bit), `float`, `string`, `bool`, `list`,
`result`, and `void`. Annotate when the type is not inferable:

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
collection or std module behind it; use models for fixed shapes and
objects for dynamic ones.

## Functions

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
refuse the call; a variable nothing fixes is refused; bodies check once with
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
capture: a value only ever names a declared function, never a lambda, and
there is no `fn` annotation to pass one as a parameter or return one. A
generic function has no one signature until a call fixes its parameters, so
only calling it is allowed; `main` is the entry point, not a value.

```orbit
fn inc(x: int) -> int {
    return x + 1
}

fn main() -> int {
    val f = inc
    return f(1)
}
```

## Errors: `result` and `try` / `catch`

A function that can fail returns `result`. The caller handles it with `try` and
`catch`; there are no exceptions and nothing unwinds implicitly.

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

## Models

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

## Unions and enums

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

`match` dispatches on a union variant.

## Control flow

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

## HTTP routes

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
generated for it, so you do not write one, and the listen port is the first
command-line argument:

```sh
orbit build greet.orb -o greet
./greet 8080
```

If you need startup work, add `fn main() -> int`; the generated server calls
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
`ok` accepts any 2xx or 3xx status; 4xx/5xx belong to `err`, which
refuses 2xx/3xx in turn.

Route annotations control admission: `route GET "/x" limit 20 / s burst 20`
sets a per-source-IP budget, enforced by the Kynx gate. See [Kynx](KYNX.md).

## Imports

```orbit
import "std/string/string.orb"
import "std/test/assert.orb"
```

Paths are relative to the importing file or to the standard library, so the
two spellings above both resolve from anywhere in the tree. The standard
library lives in [`std/`](../std); `std/test/assert.orb` provides the assertion
helpers the suite uses.

## Comments

`//` to end of line. Block comments are not part of the language.

## The CLI

`orbit build`, `orbit run`, `orbit check`, `orbit fmt`, `orbit doctor`,
`orbit frontend`, `orbit cluster`, and `orbit lextrace` (developer lexer
trace; output is unstable by design). [Commands](COMMANDS.md) has the
flags and exit codes; [FAQ](FAQ.md) has the common questions.

## What is not here yet

Raw sockets, threads, bitwise operators, and generic unions — the
`std/quarantine/` directory names the exact missing language feature
for each. [Known Limitations](KNOWN_LIMITATIONS.md) is the honest
list, and [Status](STATUS.md) says what is being worked on.
