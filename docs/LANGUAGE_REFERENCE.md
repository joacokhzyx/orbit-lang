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
declarations include `fn`, `model`, `enum`, `union`, `type`, and `route`.

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
and `type` for aliases.

```orbit
model User {
    id: string
    active: bool
}

enum Role { Admin, Member }
type UserId = string
```

The six lowercase names are the only type names the compiler knows: `int`,
`float`, `string`, `bool`, `void`, and `list`/`map`/`object`/`result`/`response`
as container and result spellings. `List`, `Map`, `Result` and `Response` are
accepted capitalised and are real. **Any other capitalised spelling is not a
type at all.** `mapTypeToC` sees a name that starts uppercase, is not one of
those four, and hands it through as `Name*` — so `val n: Int = 1` type-checks
cleanly and then gcc rejects the generated C with `unknown type name 'Int'`.
The same happens for `Float`, `String`, `Bool`, `Void`, `Any` and `DateTime`.
The one way it slips through is if you never use the binding: an unused local
is never declared in the C, so the bad type never gets written down.

Binary literals are not supported: `0b101` is the number `0` followed by junk,
silently. Neither are exponents — `1.5e2` is `1.5` followed by junk and
evaluates to `1`, and `2.5E3` declares a variable named `E3` whose type the C
compiler has never heard of. Hex (`0x1F`) and digit separators (`1_000`) do
work.

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
  `result`, consume with inline try). Uses the `.to_int()` method
  nowhere: it emits a missing helper (STAB-9); the extern
  `orbit_string_to_int` is used instead.
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
  **The element type is yours, not the compiler's.** There is no list
  element type in the language, so nothing checks what a slot holds, and
  these helpers cannot: they are written for string slots and the `*Str`
  family will not tell you otherwise. `getOr` on a list of ints
  segfaults, and `indexOfStr` on a list of lists returns `-1` without a
  word - both verified by running them. The int helpers
  (`containsInt`, `indexOfInt`) have the same exposure in the other
  direction. `orbit check` reports no errors for any of it.
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
