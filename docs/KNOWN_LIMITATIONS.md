# Known Limitations (0.1.0)

This is the honest list. I keep it next to the docs that use these
features so you don't discover them at midnight. Each entry says
what happens today, how to work around it, and what would change it.
Nothing here is a roadmap promise with a date - it's what I measured
on this build.

Verified on: `orbit 0.1.0-rc.2` (fixed-point build, gcc 13.3.0),
Windows x86-64 and Linux x86-64, September 2026. Linux paths are
marked UNTESTED below where I couldn't run them.

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

## Path parameters match, values are raw

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Two limits
remain: captured values are not percent-decoded, and at most 8
captures bind per request. Query values (`?id=`) keep working
alongside.

## Custom tables are created, not migrated

On startup the runtime creates the four built-in tables (`notes`,
`products`, `users`, `sessions`, plus demo seeds) and one table
per model in your program (`CREATE TABLE IF NOT EXISTS` from the
model fields: `string`→`TEXT`, `int`/`bool`→`INTEGER`,
`float`→`REAL`, an `id` field becomes the primary key). There is
still no migration story: adding a field later does not alter an
existing table (see `docs/guides/migrations.md`).

## Multipart uploads aren't implemented

`req.file()` compiles but maps to a stub that returns a
placeholder path and saves nothing (called with one argument it
also triggers a C arity warning). There is no multipart parsing
and no disk persistence in 0.1.0. The file-server tutorial
(`docs/tutorials/file-server.md`) uploads raw bodies and says so.

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

## No p50/p99 yet

`system.*` exposes uptime, pid, worker count, total requests, and
mean latency in microseconds. There is no latency distribution
(no p50/p95/p99) and no success/error split. `/_ledger` adds
per-route request counts, mean milliseconds, and DB share. What
isn't measured isn't exposed.

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

## An object literal cannot be a `-> model` return type

`inferType` returns the literal string `"object"` for an object
literal (`compiler/sema.orb:980`), and the return check compares
that name against the declared one. A model name is not `"object"`,
so the comparison fails and you get a mismatch naming a type that
was never in your source:

```orbit
model Point { x: int, y: int }
fn make() -> Point { return { x: 1, y: 2 } }
// Semantic error: Return type mismatch: expected Point, got object
```

The literal itself is fine - the feature landed, and `orbit check`
accepts it as a model field, as a local, and as a `response` body.
Only the `-> model` annotation is unreachable. Workaround: build
the model with its constructor and return that, or return the
literal from a function typed `-> response`. (Reading a value back
out of an object with `.get()` is a separate miscompile - see
"a list slot has no element type" below, and
[LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#maps).)

## A generic model typechecks, then emits C that does not compile

`model Box[T] { v: T }` passes `orbit check` with no errors and then
fails in the C step:

```console
$ orbit build gen.orb -o gen
  <build>:74:5: error: unknown type name 'T'
  <build>:77:63: error: unknown type name 'T'
  <build>:91:29: error: unknown type name 'T'
```

`T` reaches the emitter as an ordinary type name, `mapTypeToC` has
no case for it, and the backend helpfully casts it to `void*` in
register declarations while emitting a bare `T*` in the struct and
the constructor. There is no monomorphisation, so a generic type
parameter is a name with nothing behind it. This is the same root
cause as the quarantined `std/quarantine/option.orb.quarantined`:
`Option<T>` cannot be written until this can.

## `orbit fmt` splits a negative literal after `return`

`return -1` comes back as `return - 1`:

```console
$ printf 'fn main() -> int {\n    return -1\n}\n' > t.orb
$ orbit fmt t.orb && grep return t.orb
    return - 1
```

It is specific to `return`. `val x = -1`, `print(-1)`, `f(-1)` and
`3 * -1` are all left alone, and so is `return - 1` if you write it
that way already — the formatter is idempotent, it just disagrees
with you about the first pass. It still compiles and still returns
-1, so this is cosmetic. It is listed because the formatter is
treated as authoritative by `fmt --check`, and applying it has
therefore spread `- 1` through 15 sites across 5 files (`std/io/io.orb`,
`std/bytes/bytes.orb`, `std/sys/crypto/jwt.orb`,
`std/collections/lists.orb` and `lib/arena.orb`). Fixing
`compiler/fmt.orb` will need a re-run of `fmt` over those trees.

## A list slot has no element type, so nothing can check it

`OrbitList` is `{ void* data; size_t len, capacity, elem_size; ... }`
(`runtime/types.c:195-201`). One pointer per element, and nothing
records what it points at. This is the single most load-bearing gap
in the language - it is why an unannotated binding is assumed to be
a string, and it is why the `std/collections/lists.orb` helpers
cannot protect you:

| program | result |
|---|---|
| `getOr([1,2,3], 0, "d")` bound to a `string` | **segfault** |
| `indexOfStr([[1,2],[3,4]], "x")` | `-1`, silently |
| `[10,20,30].at(0)` | the low byte of the `data` pointer - 48, 144 and 0 in three programs differing only in what else they allocated |
| an object `{ "a": 1 }`, with `.get("a")` bound to an `int` | segfault |

`orbit check` reports no errors for any row. A method call directly on a
literal does not parse (`Expected ')' after arguments`), so each of these needs
the value bound to a `val` first — which is what I did. Use `.get(i)`, not
`.at(i)`, and treat a list's contents as something only you know.

## 30.5% of instructions are `unknown`, and 46.6% of those are silent

`scripts/unknown_census.py`, run over 92 files and 35,814
instructions on this build:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 10,940 | **30.5%** |
| ...with no diagnostic at all | 5,102 | **46.6% of the unknown** |
| ...of those, opcode `call` | 2,697 | |
| ...of those, opcode `member` | 2,405 | |

The silent half is the honest number. E2001/E2002/E2003 account for
the rest to the unit - their counts equal the unknown `load` /
binary / unary counts exactly - so 5,102 is measured, not
estimated. Those are `call` and `member` expressions: the two
places where the front end does not know it has failed, and the same
name-and-shape classification as the list problem above.

Separately, E3001 "expression cannot be lowered to TIR" fires 4,048
times. That is a whole class of expression the front end gives up
on, and it is not in the unknown total because there is no
instruction to type. Worst file by share: `compiler/parser.orb` at
49.7% (2,146 of 4,316).

Run `python scripts/unknown_census.py --compiler <orbit> --json`
for the per-file breakdown. It is wired into CI as a **report-only**
step with `continue-on-error: true`, output to the job summary, and
must never become a gate: the number is a measurement, not a
threshold.

## Two of the six frontend fixtures do not build

`scripts/frontend_gate.py` runs six fixtures. Four pass. Two -
`tests/frontend/syntax_error.orb` and `tests/frontend/unresolved_type.orb`
- cannot build, so **their contracts have never been checked at
all**. `orbit check` is clean on them; the C step fails, because
`import compiler/frontend/frontend.orb` reaches `compiler/parser.orb`
then `compiler/lexer.orb`, and the lexer calls
`orbit_os_write_stderr_selfhost` without importing
`compiler/extern.orb`:

```console
  <build>:4920:20: error: invalid use of void expression
  <build>:9810:31: warning: implicit declaration of function 'parseIntSelfhost'
```

The second one is a third missing import, in `compiler/builder.orb:199`.
Both are in the compiler zone, not the docs one. The four TIR
goldens that do run all pass, so the gap is coverage, not
correctness. [ENGINEERING.md](../ENGINEERING.md) step 6b records it
so the gate's 4/6 is not mistaken for a passing 6.

## `lib/net.orb` does not build

It type-checks and then the generated C is rejected: the module
declares `extern fn syscall(n, a1, a2, a3)`, which collides with
the real `syscall` in `runtime/socket_compat.h`.

```console
  <build>:121:18: error: conflicting types for 'syscall'
  <build>:121:18: error: static orbit_int syscall(...);   // ours
     41 | #include <sys/syscall.h>                            // glibc's
```

Its event loop is `while running { ... running = false }`. It is a
design sketch and is documented as one; it is not a working wrapper,
and there is no socket API in the language or the runtime.
`docs/ARCHITECTURE.md` says the same.

