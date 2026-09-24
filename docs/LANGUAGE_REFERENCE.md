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

## Control flow

Orbit supports `if` / `else`, `while`, an unconditional `loop`, and iteration
with `for … in`. `break` and `continue` are valid within loops.

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
calls, member access, arrays, object literals, and string interpolation.

## Arrays and objects

Array literals use brackets. Object literals use named fields.

```orbit
val ports = [8080, 8081]
val service = { name: "api", healthy: true }
print("${service.name} on ${ports[0]}")
```

String literals support `\n`, `\t`, `\r`, `\"`, `\\`, and the byte
escape `\xHH` with two hex digits (`"\x41"` is `"A"`, `"\x1b"` starts
an ANSI sequence). Anything malformed stays literal.

Collection APIs and their exact type coverage are still evolving. Keep business
logic simple and cover it with application-level tests. If something you need isn't here, file an issue - I read everything.

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
can be constructed and returned by the current compiler. A `try` expression
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

## Standard library (Wave 1)

Shipped and tested under `tests/std/` (run with
`test_suite.py --dir tests/std`):

- `std/test/assert.orb`: `assertTrue`, `assertEqInt`, `assertEqStr`
  for exit-code tests. No `assertErr`: try/catch on a result
  parameter miscompiles today (STAB-9); use inline try/catch.
- `std/string/string.orb`: `trim`, `startsWith`, `endsWith`, `join`,
  `split`, `padLeft`, `padRight`, `toUpper`, `toLower` (byte-wise,
  ASCII-only), `parseIntChecked` (canonical decimal only; returns
  `result`, consume with inline try). Uses the `.to_int()` method
  nowhere: it emits a missing helper (STAB-9); the extern
  `orbit_string_to_int` is used instead.
- `std/hash/hash.orb`: `sha256Hex`, `hmacSha256` (runtime bindings).
  No `fnv1a32`: bitwise operators have no lexer tokens yet.

Call fallible std functions with inline try on the call
(`val n: int = try parseIntChecked(s) catch { ... }`); binding the
result to an untyped `val` first miscompiles (STAB-9).

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
orbit doctor [dir]                 # Read-only project checks
orbit cluster ...                  # Single-host orchestration (see CLUSTER.md)
orbit --help                       # Display the command-line help
orbit --version                    # Display the compiler version (0.1.0)
```

`orbit dev` (watch/reload), `orbit test`, `orbit bootstrap`, and
`--backend=` flags are not implemented. Calling them treats the word as a
filename and fails. See [Command Reference](COMMANDS.md) for the supported
list and exit codes.
