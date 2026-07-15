# Orbit language reference

Orbit source files use the `.orb` extension. This reference covers the syntax
implemented by the `0.1.0-rc.2` compiler. The language remains pre-1.0, so new
projects should keep their dependency on a specific release candidate.

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

Collection APIs and their exact type coverage are still evolving; keep business
logic simple and cover it with application-level tests.

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
Their API surface is under active development; consult the runtime and examples
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

## Compiler commands

```sh
orbit build app.orb
orbit run app.orb
orbit test app.orb
orbit bootstrap --stage=3 --verify
```

See [the release status](../STATUS.md) for backend and platform limitations.
