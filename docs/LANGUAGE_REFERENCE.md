# Orbit language reference

Orbit source files use the `.orb` extension. This reference covers what the `0.1.0` compiler does today. The language is pre-1.0, so pin your dependency to a specific release candidate and expect gaps — I document limits alongside features.

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

Collection APIs and their exact type coverage are still evolving. Keep business
logic simple and cover it with application-level tests. If something you need isn't here, file an issue — I read everything.

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
function. Binding the error payload to a named variable remains future work.

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

The compiler recognizes standard modules including `crypto`, `jwt`, `http`,
`file`, and `server`. Module organization and import ergonomics are not yet
stable, so keep module boundaries small and pin the compiler version in CI.

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

Every server records per-route handler cost automatically — no annotations.
`/_ledger` serves a live table (loopback only), `/_ledger/data` the same as
JSON. Columns: requests, mean ms, DB share, energy, source. Milliseconds share the request
log's approximate clock basis. The energy column reads joules per request
(estimated route share, see `docs/ENERGY.md`) where a power sensor exists,
and a labeled CPU proxy in cycles where it does not — never converted.
Paths starting with `/_` are reserved for
runtime endpoints; do not define routes there.

## Compiler commands

```sh
orbit build app.orb                # Default C target
orbit build app.orb --backend=c     # Explicit C target
orbit build app.orb --backend=native # Experimental x86_64 target, not stable yet
orbit run app.orb                  # Compile and execute
orbit test app.orb                 # Run test blocks
orbit bootstrap                    # Multi-stage self-hosting bootstrap
```

`--backend=native` is research in progress. The C backend stays the supported path until native matches it on behavior and bootstrap checks. See [Project Status](STATUS.md).
