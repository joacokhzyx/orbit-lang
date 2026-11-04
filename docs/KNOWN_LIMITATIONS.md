# Known Limitations (0.1.0)

This is the measured list. It sits next to the docs that use these features, so
a limit is found before midnight. Each entry says what happens today, how to
work around it, and what would change it. Nothing here is a roadmap promise
with a date. It is what was measured on this build.

Verified on: `orbit 0.1.0` (fixed-point build; gcc 16.2.0 on Windows x86-64
and gcc 15.2.0 on Linux x86-64), November 2026. Both hosts ran the full gate
sequence. Linux paths are marked UNTESTED below where the run was not
performed.

**Start with the first section.** Everything below that one is a feature
gap you can design around. The first section is about the programs `orbit
check` refuses, which used to be the reason to distrust it: nineteen of them
translated cleanly and computed something else. All of those are diagnostics
now, and the section records what they answer instead. It includes the two
checks that were wrong in the direction of refusing valid code, which is the
failure mode worth reading about.

## Doctor over a whole tree fits the machine it runs on

`orbit doctor compiler` is one process. It typechecks every file it walks and
releases nothing, so the scan has to fit under the ceiling on committed bytes. On
2026-11-03 it fits on both hosts with `ORBIT_ARENA_MAX_MB` unset. The 3904 MB WSL
instance answers `doctor: 141 finding(s) (0 error(s), 141 warning(s)) in 28 files
under "compiler"`, exit 1. On an 8192 MB Windows host the lowest ceiling that
completes is 432 MB, and 416 MB aborts.

`doctorCodePart` (`compiler/tools/doctor.orb:4049`) is what changed. It quoted the
string runs of a line through a chunk buffer. A buffer's first block is
`ORBIT_CBUF_INIT_CAP`, 65536 (`runtime/collections.h:189`), and the arena holds it
until the process ends. So every line carrying a quote cost 64 KB, whatever the run
was. Joining the runs with `+` asks for the bytes the text has. Before that, the
same command on the same 3904 MB host aborted at exit 134 with `3070599168 of
3070620672 bytes committed, the limit is 2928 MB` -- measured 2026-11-02 with the
fixed point `2d61febad7ca13e1`.

The release still cannot be written in this language: the arena is not a value an
Orbit program names. The emitter resolves it as the caller's arena or the process
global (`compiler/emit/c_backend.orb:1292`), and the only `orbit_arena_create` calls
in any `.orb` file sit inside the C text the emitter prints. A scoped arena the
source can select is the change that makes the ceiling beside the point rather than
merely high enough, and it is the open item.

`scripts/doctor_gate.py` scans the directories that must be clean, and when one
process cannot hold a directory it retries it one subdirectory at a time. That retry
is unreached on both hosts today: `--scope-only` answers `Finished doctor_scope: 3
directories clean (compiler, std, tests/suite)` with no kill and no split. This is
the same gate read on 2026-11-02, before the change, on the 3904 MB host with no
`ORBIT_ARENA_MAX_MB`:

```console
note: compiler: doctor was killed by a signal (-6): orbit: arena ceiling reached
allocating 65536 bytes; 3070599168 of 3070620672 bytes committed, the limit is
2928 MB from ORBIT_ARENA_MAX_MB; retrying as 7 subdirectories
note: compiler: 141 advisory finding(s) not counted
Finished doctor_scope: 3 directories clean (compiler, std, tests/suite).
```

The gate sequence as a whole is green on that 3.9 GB host without
`ORBIT_ARENA_MAX_MB` set -- `all 26 gate(s) passed in 281s`, read on 2026-11-03
with the compiler this page describes.

## Doctor skips tool state: dot-directories and what .gitignore names

A directory whose name begins with a dot is not scanned, so `.orbit/` with its
thousands of build copies never is. The `.gitignore` of the directory being
entered is read too, so a rule written in a subdirectory applies to that subtree
the way git does, and a leading `/` anchors a rule to the directory that wrote
it instead of applying it at every depth. Wildcards, negation (`!name`) and
rules that name a path below the directory (`scripts/dist/`) are left to git:
`*` is not interpreted, because a guessed pattern match silently drops files
from a scan, and a scan that hides source is worse than one that reports it
twice.

With both rules, `orbit doctor .` over this repository scans 488 files and
reports 448 findings (140 errors, 308 warnings) in 502 files on Windows, measured
on 2026-11-03 with the compiler the section above describes. Three `fuzz_crashes/`
cases a fuzz run left in the working tree were in the scan when this paragraph was
first written -- 451 findings in 505 files -- and `.gitignore` now names that
directory, so the walk does not report them. The 3904 MB Linux run now reports the
same 448 findings and reaches
no ceiling; the ceiling is the section above, and the walk is not it.

## The silent group is empty

This section used to be called *nineteen programs the compiler should reject
and does not*, and it was the reason this document existed. Every entry in it
is now a diagnostic, so it has been replaced rather than kept as a museum.

The reason to write that down rather than just delete the heading is that the
document depended on the list. It is the evidence that `orbit check` is worth
running. One command produced it, and that command is also a CI gate, so it
could not rot quietly:

```console
$ make negative
...
Finished negative: 115/115 pass (0 known defects still accepted)
```

One hundred and twelve programs: every one must be rejected and is. The last one
to be fixed was F-0025, the assignment target: a `val` store, a type mismatch
and an undeclared name now produce E1009. Before it,
[a `list` parameter with no element type](#a-list-carries-an-element-type-now-and-the-checker-enforces-it)
was the last, and generic functions gave it a diagnostic. What remains is a
design choice (the bare `list` spelling stays lenient for dynamic values), not
a missing check.

## A shadowed `val` gets its own C variable (fixed)

This one used to compute something other than what you wrote: it typechecked,
it ran, and the answer was wrong. The checker always resolved it correctly --
`v` inside the `if` is a different `val` with its own scope -- but the emitter
declared one C variable per *name*. So both `val v` became a single
`orbit_int v`, and the outer read came back clobbered:

```orbit
fn f(flag: bool) -> int {
    val v = 10
    if flag {
        val v = 20
    }
    return v    // was 20, is 10
}
```

Every declaration now owns a distinct C symbol, minted where the IR value is
created (`defineVariable` in builder.orb). It is the spelling when no live outer
scope declares it, and `name__sN` when one does. It is resolved innermost-first
at every read and write. Without shadowing the symbol IS the spelling, which is
why the canonical barely moved. Pinned by
`tests/suite/scope_shadow_clobbers_outer.orb` (exit 0, including the
parameter-shadowing case).

## Four bugs that typechecked, ran and were wrong

None of these was a missing check. Every one compiled clean, ran, and produced
a wrong answer, which is why no gate found them. A gate runs the program and
compares what it prints, and a program that prints `7.0` instead of `7` prints
something.

They are one class, and the class is worth more than the four entries:

- **A name derived in two places.** A field read was typed from a scan of every
  field *name* in the module, last match winning, instead of from the model that
  owns the field. Two models sharing a field name with different types read each
  other's member.
- **A rule implemented twice.** Checker and emitter each peeled one `list<>` to
  find a generic parameter. The checker peeled to any depth and the emitter to
  one, so the same literal checked as `list<list<float>>` and built as
  `Nested_unknown`.
- **A cast inherited from its neighbours.** The float arm of a constructor
  argument read `(orbit_float)(uintptr_t)(x)`, written to match the int arm
  beside it, where the `uintptr_t` hop is harmless. For a float it truncates, so
  every float model field lost its fraction.
- **An empty string used as "no value".** A parameter not resolved to an
  instance was defined with an empty type name. Empty is not `unknown`: a symbol
  with no type resolves to nothing, and the first field read through it loaded a
  field no declaration named.

The pattern: **wherever the checker and the emitter must agree on a derived
name, that derivation has one implementation and one test that pins it.** Two
implementations is a coin flip that lands wrong at runtime rather than at build
time, which is the only place a coin flip is not allowed to land.

Where the shared derivations live, and why that file exists: `literal.orb` is a
leaf module importing nothing, so `builder.orb`, `sema.orb` and `parser.orb` can
all depend on it and the import graph stays a DAG. It was created for exactly
this reason ([F-0004](ERROR_CODES.md#f-code-index)). A helper in the wrong side of the graph was an unresolved
call, which is not an error: `orbit check` stayed clean and the C compiler
rejected the output with a name it had never been given.

The tests that pin all four are `tests/suite/model_field_owner_typing.orb`,
`generic_nested_argument.orb` and `parameter_type_fallback.orb`.

What replaced the list, in the order the work was done:

| what used to happen | what happens now |
|---|---|
| `.at()` on a list read a byte of the list pointer and answered 0 | `.at()` and `.get()` both do the right thing, on ints and on strings |
| a call argument's type was never compared with the parameter's | [`E1005`](ERROR_CODES.md#e1005--call-argument-type-mismatch), naming the parameter and both types |
| an undeclared identifier printed a stack address | *Undeclared identifier: nothing in scope declares it* |
| a call with the wrong arity dropped the extra arguments | *Wrong number of arguments to f: it takes 1, got 3* |
| a model constructor accepted the wrong argument types | [`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity), naming the field and both types |
| `1e2` was the integer `1`, `0b101` was the integer `0` | both are literal values; an exponent is always a float |
| `(0-7)/2` was `-4` and `(0-7)/3` was `1431655763` | `-3` and `-2`, C semantics, pinned by `div_mod_signed.orb` |
| `9223372036854775808` silently became `-9223372036854775808` | *integer literal does not fit an orbit_int* |
| `s.at(99)` answered 0, which is the NUL byte | [`E1002`](ERROR_CODES.md#e1002--literal-index-out-of-range), naming the index and the length |
| `val v: widget = 3` was ignored | [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch), and a capitalised unknown type is refused too |
| `val n: Int = 1` reached gcc as `Int*` | [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch), with the note that types are lower case or declared |
| `m.nonexistent`, `s.radius`, `n.nothing` died in the C step | [`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity), and the receiver's own members are the only ones |

Two of those deserve a note about *how*, because both were the same mistake
wearing different clothes.

**A check that only knows one table is a check that guesses.** [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch) refuses
a capitalised type name that nothing declares, which is what makes `val n: Int
= 1` a diagnostic. Its first version asked the checker's two type registries,
and those registries do not hold models. `checkModelDecl` fills
`modelFieldOwner` and `TypeDecl` never sees a model, so it also refused
`List`, `Map`, `Result` and `Response`, which are real. Forty-three green
tests did not notice, because nothing in the suite used the capitalised
spelling. `tests/suite/type_spellings.orb` exists so that it cannot happen
again.

**The loud group is now silent too.** The table this section used to carry is
empty. It listed programs that translated cleanly and were rejected by the C
compiler, with an error naming a C symbol or a C struct member instead of the
Orbit source. Those messages reached the user as `orbit build: couldn't finish
the C step - this one is on me, not your code`, which is a sentence about the
compiler's feelings, not about the program. Every one of them is now an
[`E1003`](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity) with a line and a column in the user's own file.

The mechanism underneath is described in
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag),
and the measurement that says how much of the front end is still untyped is
[below](#194-of-instructions-are-unknown-and-every-one-of-them-says-so).


## Writes work, but duplicates and missing tables fail

`Model.create()` stores the row and returns `true`. It returns
`false` when the `id` already exists (PRIMARY KEY) or the JSON
payload has no usable fields. `Model.update(id, json)` writes only the
keys present in the payload (never `id`) and returns `true` only when a
row actually changed. A missing id or a fieldless payload is `false`.
`Model.delete()` returns `true` only
when a row was actually removed. Verified live with literal JSON
and `req.body()` input, including round-trip reads
(`examples/posts_crud.orb`).

## Auth helpers work against the sessions table

`req.bearer_token()` extracts the token and never crashes on missing
headers. `req.has_role("admin")` and `req.role()` resolve through
`sessions` joined to `users.role_name`, with `expires_at` honored
(`0` means never). Verified live on `examples/sqlite_notes.orb`:
401 without token, 403 for non-admin deletes, 200 for admin.
Using any auth helper links the database automatically. Tokens
themselves are rows you insert (see `tests/auth/auth_harness.c`).

## Path parameters match, values are decoded

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Captured
values are percent-decoded by `req.param()`. The capture table belongs to
the request and grows with the pattern, so the count is the route's, not a
fixed slot count. Query values (`?id=`) keep working alongside.

## Custom tables are created, and DDL migrates both ways

On startup the runtime creates the four built-in tables (`notes`,
`products`, `users`, `sessions`, plus demo seeds) and one table
per model in your program (`CREATE TABLE IF NOT EXISTS`). The columns
come from the model fields: `string`→`TEXT`, `int`/`bool`→`INTEGER`,
`float`→`REAL`, and an `id` field becomes the primary key. Forward
DDL now runs through `migrations "<SQL>"` lines (each once, in
declaration order, tracked in `_orbit_migrations`). See
`docs/guides/migrations.md`. A database whose schema is newer than the
program is refused at startup: if `_orbit_migrations` holds a version this
program does not declare, it prints the version and exits non-zero instead of
running old code against columns it cannot describe. `migrations down "<SQL>"`
undoes its forward line, and `ORBIT_MIGRATE_DOWN=<version>` rolls back every
applied version above it at startup, newest first, then stops. `orbit migrate
<file>` runs the same block without starting the service.

## Multipart uploads save files to disk

`req.file(field_name, dest_dir)` now parses `multipart/form-data`
boundaries, matches the part by `name=`, sanitizes the part's
`filename=` (path stripped, safe chars only), and writes the part
payload to `dest_dir/<name>`. Returns the saved path or "" when the
request is not multipart or the field is absent. Binaries containing
NUL bytes are length-delimited on the wire but cannot round-trip as
`orbit_string`. Treat them as saved bytes. Pinned by
`runtime/test_upload.c`.

## Cluster is single-host only

`orbit cluster` starts N copies of one service on this machine.
There is no shared state, no proxying, no failover, and no
multi-host story. `up`, `status`, and `down` are verified in the
deploy tutorial. `drain` and rolling restart follow the platform
rule below.

## No joules on Windows

Energy is reported in joules only where sensors exist (Linux
RAPL). On Windows the proxy is CPU time plus memory -
never converted to joules with a universal factor. The measurement
record in [Resource and Energy Measurement](ENERGY.md) enforces this.

## A latency percentile is estimated inside its bucket (fixed)

`system.latency_p50_us()`, `latency_p95_us()`, and `latency_p99_us()`
exist alongside uptime, pid, worker count, total requests, and mean
latency. They read a histogram of 1000 buckets of 100 µs up to 100 ms, then
20 buckets of doubling width -- 100-200 ms, 200-400 ms, and so on, with the
last one starting near 14.6 h (`runtime/performance.h:164-267`).

The bucket alone says only that the value lies between two edges, and the edge
was the answer: a 300 ms p99 reported 400 ms, the top of the bucket holding it.
Each bucket now also sums the microseconds it received
(`orbit_perf_lat_sum_us`), and the estimate is anchored on that mean and spread
by rank -- `mean + width * (rank - half) / count`, clamped to the bucket. A
bucket holding one request answers that request, so the 300 ms p99 reports
300 ms; a bucket holding a uniform spread answers within one rank step of the
value at that rank. `runtime/test_latency_percentiles.c` pins the one-sample
case, the 100-sample spread, both clamps and the fallback.

Only the final bucket has no upper edge of its own, and it is answered from the
recorded maximum. Before the doubling, every request slower than 100 ms shared
one bucket and the percentile *was* that maximum -- a different quantity from a
percentile, presented as one.

The same rule holds for the per-route percentiles `/_ledger` serves. That table
keeps its own histogram in `runtime/ledger.c`, one bucket per power of two of
handler cycles, and each bucket now also sums the cycles it received
(`lat_sum`), which doubles its static state from 32 KB to 64 KB across the 64
route slots. `runtime/test_ledger_percentiles.c` pins the one-request case (a
10 ms outlier answers 10000 us, not the 13421 us edge above it), a 100-request
spread inside one bucket, and both clamps.

Requests are split by class at the send path: `system.http_requests_ok()` counts responses below
400 and `system.http_requests_error()` counts 400 and above.
`/_ledger` adds per-route request counts, mean milliseconds, and DB
share.

## A Windows stop drains through a named channel

Draining works on Windows. The emitted loop that finishes adopted and
queued connections before exiting is not platform-guarded
(`compiler/emit/route_runtime.orb:442`), and a Windows server registers a
console handler that requests the stop on `CTRL_C_EVENT` and
`CTRL_BREAK_EVENT` (`compiler/emit/route_runtime.orb:625-632`, registered at
`:758`). Ctrl-C on a console `orbit run` therefore drains there as it does
elsewhere.

The gap was the ask from another process. `orbit_os_kill` took a mode and
ignored it on Windows, and children are created with
`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` (`runtime/os.c:399`), so there is
no console for `GenerateConsoleCtrlEvent` to deliver an event into. The ask is a
named event now, and the name is the pid, because the pid is all the stopper
knows:

- the server opens its own channel at start
  (`compiler/emit/route_runtime.orb:767`);
- the worker loop polls it after every `select`
  (`compiler/emit/route_runtime.orb:460`), so a stop is seen within the loop's
  1 s timeout, and the request is the same `orbit_request_stop()` the console
  handler raises;
- `orbit_os_kill(pid, 1)` asks the child through `orbit_stop_channel_ask`
  (`runtime/os.c:511`), and when no channel carries that pid it falls back to
  `TerminateProcess` (`runtime/os.c:514`).

POSIX answers 0 from all three calls and keeps SIGTERM, so one emitted code path
runs on both hosts with one graceful-stop mechanism each.
`runtime/test_stop_channel.c` pins the open, the ask, the poll and the
manual-reset repeat on Windows, and the no-op answers on POSIX.

Measured through the CLI in three steps: **193 ms** before the wait below was
fixed, and the service was terminated; **1074 ms** with the wait fixed and no
channel, and the service was still terminated; **1108 ms** with the channel, and
the service's own output ends with `Server stopped.` -- the printf that runs only
after the workers join (`compiler/emit/route_runtime.orb:816`). `cluster down`
on one node measures 5.1 s and its `node-0.log` ends with that line too: the
wait loop steps in whole seconds, so a drain that is over in 1.1 s is noticed on
the next tick.

A second defect hid behind the missing channel, and it made the wait itself a
lie.
`orbit stop` and `cluster down` ask mode 1, then escalate to a kill after
three seconds -- except the wait was `clusterSleepSec`, which slept by
spawning `timeout /T 1 /NOBREAK`. `timeout` refuses to run when its input is
redirected, so every "second" returned at once: the documented three-second
grace measured **193 ms** for `orbit stop` and 306 ms for `cluster down`, and
the service was terminated before its accept loop could notice anything. The
helper has 11 call sites, and the damage differs by helper. `clusterWaitDead`
and the `orbit stop` escalation poll for a *change*, so an instant retry loop
gave up after a few hundred milliseconds and forced the kill.
`clusterWaitAlive` probes before it sleeps and asks only whether the pid is
alive, so it answered on its first probe and never waited for a listener --
which is honest, because cluster health is a process probe, not a readiness
check.

`clusterSleepSec` now blocks the thread on `orbit_sleep_ms`
(`runtime/builtins.c:133`), which cannot be skipped by the state of a handle;
`runtime/test_sleep.c` pins the lower bound and the zero/negative answers.

What is left: a child that never reached the server start has no channel to
answer -- one that failed before the listener opened, or one built before this
channel existed. There the stop is still a kill, and it is the honest outcome:
nothing waits on the name.

## Two servers, one port: both platforms refuse it

The listener is exclusive on both platforms. Windows sets
`SO_EXCLUSIVEADDRUSE`; Linux sets `SO_REUSEADDR` and nothing more. A second
process on an occupied port prints `Port N is not available. Another program
may be using it.` and exits 1, on either host.

Until 2026-11-01 the emitted listener also called `orbit_enable_reuseport()`, a
helper in `runtime/socket_compat.h` that set `SO_REUSEPORT` on Linux only. A
second Linux server bound the port anyway and the kernel distributed
connections between the two processes. A port mistake served traffic instead of
failing.

Nothing needed that sharing. `orbit cluster up` gives every node its own port
(`--port-base P`, ports `P..P+N-1`, `compiler/host/cluster.orb:438`), and
`orbit dev` stops the child and waits up to 3 s for it to die before respawning
(`compiler/host/start.orb:481-485`), so the port is free before the new bind
runs. `SO_REUSEADDR` still covers what a restart actually meets: the previous
process's TIME_WAIT sockets.

Measured on WSL Ubuntu before the change: with the first server listening, the
second printed its own banner and was still serving when `timeout 4` killed it
(exit 124). Measured after, with a fixed point built from the new canonical:
exit 1, the two-line port message, and one listener
(`ss -lntp | grep -c 47812` prints `1`). The live gate pins it on both hosts
now: `scripts/kynx_gate.py live` starts a second server against the occupied
port while the first is listening, and fails unless that second process refuses
with the port message.

`ss -lntp` (or `netstat -ano` on Windows) names the process holding the port.

## A generic model monomorphises; an expression infers the argument, a signature writes it

`model Box[T] { v: T }` works. The type argument comes from the value
written for the field that uses it, and each instantiation is its own C
struct:

```console
$ cat box.orb
model Box[T] { v: T }
fn main() -> int { val b = Box { v: 1 }  print(b.v)  return 0 }
$ orbit check box.orb
Checked box.orb: no errors.
$ orbit build box.orb -o box && ./box
1
```

`Box { v: 1 }` is `Box_int` and `Box { v: "hi" }` is `Box_string`. The written
form in a signature is not decoration either, and was run again on 2026-11-02:

```console
$ cat box.orb
model Box[T] { v: T }
fn take(b: Box<int>) -> int { return b.v }
fn main() -> int { val b = Box { v: 1 }  if take(b) != 1 { return 7 }  print(b.v)  return 0 }
$ orbit check box.orb
Checked box.orb: no errors.
$ orbit build box.orb -o box && ./box
1
```

`tests/suite/generic_models.orb` covers the same path as its seventh case, named
`aSignatureNamesTheInstance`. The generated C says so:

```c
typedef struct Box_int { orbit_int v; } Box_int;
static inline Box_int* orbit_model_Box_int_create(OrbitArena* arena_, orbit_int v);

typedef struct Box_string { orbit_string v; } Box_string;
static inline Box_string* orbit_model_Box_string_create(OrbitArena* arena_, orbit_string v);
```

There is nothing new in the emitter. An instantiation is an ordinary
model whose fields are already substituted, so it goes out through the
code that has always emitted a model struct. `mapTypeToC` is handed
`int` where the declaration said `T`. It still has no case for `T`, and
still does not need one. The generic declaration itself is never emitted.

**Why the literal infers but a signature names.** There is no grammar
for a type argument at an *expression* site: `Box<int>` lexes as a
comparison, and adding that grammar is a far bigger change than the
feature is worth. An annotation is a different position -- `parseTypeName`
already reads `list<string>` -- so a signature may write the argument out:

```orbit
model Box[T] { v: T }
fn take(b: Box<int>) -> int { return b.v }
fn make() -> Box<int> { return Box { v: 3 } }
```

`Box<int>` is not decoration. It names the instance the literal infers, and
the checker and the emitter have to agree on that string. Otherwise the program
passes `orbit check` and reads the wrong member. So the instance name is
built by one function in `literal.orb`, which both sides import -- the same
reason that module exists. `Box` with NO argument is still refused in a
signature (n51). A signature is written before any value exists, so there
is nothing to infer from, and the emitter would be handed a struct name
that only ever exists as `Box_int`.

### What is still refused, and where

| you write | what happens |
|---|---|
| `Box { v: 1 }` | `Box_int`. The supported spelling. |
| `Box(1)` | [E1003](ERROR_CODES.md#e1003--bad-member-read-bad-construction-bad-print-arity). The positional form has an argument and no way to call it an int. (n47) |
| `fn take(b: Box<int>)`, `-> Box<string>` | Supported. The written argument names (and creates) the instance. |
| `fn take(b: Box)` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch). Nothing to infer from before the value exists; write the argument. (n51) |
| `model Box[T: int]` | Parser error. A constraint is a promise about an argument this language infers, so there is nothing to hold it to. (n53) |
| `model Phantom[T] { id: int }` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch): no field's declared type mentions `T`, so there is no value to take the argument from. `void*` would compile, and would be a lie about the model. (n52) |
| `Same { a: 1, b: "s" }` where `model Same[T] { a: T, b: T }` | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch). `a` fixes `T` at `int` and `b` is then checked against it. (n50) |
| `model Box[T] { v: list<list<T>> }` | `T` is not determined. Only a field declared `T`, or a `list<T>` whose value is a list literal, fixes an argument. |
| `Option.None` where no position writes a type | [E1006](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch): `'Option.None' carries no payload, so nothing in this expression says which instantiation of 'Option' it is and no position writes a type for it either.` (n118) |

Two parameters work, and two instantiations of one model in one program
are two structs:

```orbit
model Pair[A, B] { left: A, right: B }
val ints = Pair { left: 1, right: 2 }      // Pair_int_int
val strs = Pair { left: "a", right: "b" }   // Pair_string_string
```

**A field read has to be typed off its owner.** This is worth knowing
because it was a live defect and monomorphisation made it easy to hit.
Two models declaring the same field name with different types used to
type each other's member reads from a module-wide scan of field *names*,
last match winning. `Pair_int_string` and `Pair_string_int` both have a
field called `second`, so any program instantiating one generic model
twice walked straight into it. The read is now typed from the model the
field reference names, which the builder had been writing down and the
backend had been discarding.

## Two unions may declare the same variant name (fixed)

`Signal.Body("s")` used to be refused while `Body(3)` -- with `Packet` and
`Signal` both declaring `Body` -- used to be accepted. One lookup caused both:
the registry is keyed by the variant's own name, so the first row holding it
answered for every union. The payload of a construction naming `Signal` was read
out of `Packet`, and the constructor macro was named after the variant alone, so
the second `#define Body` replaced the first.

Both directions are pinned. `tests/suite/union_shared_variant_name.orb` declares
`Packet.Body(int)` and `Signal.Body(string)`, constructs each qualified, matches
each with a qualified pattern and with a bare pattern under its own scrutinee,
and exits 0. The checker reads a payload from the owner the program wrote --
`variantPayloadAt(sema, owner, variantName, idx)` (`compiler/front/sema.orb:755`)
-- and a bare pattern resolves through the scrutinee's type in `bareVariantOwner`
(`compiler/ir/builder.orb:2405`). The constructor macro carries both names:
`val mvMacro = cUserName(mvType.name + "_" + mvName)`
(`compiler/emit/c_backend.orb:100`) where it read `cUserName(mvName)`. The two
programs that would have collided link and run, which is what the name is for.

What is refused is the case with no owner to read. `val p = Body(3)` with both
unions in scope answers
[E1011](ERROR_CODES.md#e1011--variant-name-belongs-to-more-than-one-union),
which names both owners, and `tests/negative/n121` pins the text. There is no
expected type to infer an owner from -- `checkNode` takes none -- and the guess
was the half of the old defect that said nothing.

A `match` binding carries its payload type. `checkPatternBindings` declares each name with the payload the resolved owner declares, so `tests/suite/match_binding_payload_type.orb` reads an int, a string and a model through the three payloads of one union, and `tests/negative/n122` pins the refusal when an arm body uses the binding as another type: `Parameter 1 of shout is declared string but the argument is int`. The construction is what still has nothing to read: `val p = Body(3)` with two owners is refused with `E1011`, because `checkNode` takes no expected type. The generic union does not wait on that channel, because a union instance names its union (`Option.None`, not `None`) and the type comes from the position that writes it.

## A generic union has instances (fixed)

`union Option[T] { Some(T)  None }` was refused at the declaration. Nothing
substituted an argument, so a payload declared `T` reached the C backend as the
parameter's own name. A `T` in the generated C is not a type, and the program
that got there failed at the C compiler rather than at `orbit check`.

The argument now comes from the positions that already write a type, and there
are four of them: a parameter declaration (`fn takeInt(o: Option<int>)`), a
binding annotation (`val a: Option<int> = Option.Some(21)`), a `return` inside a
function whose result is declared, and a call argument checked against its
parameter. `Option.Some(21)` adds a fifth: a payload-carrying construction fixes
the argument from the value handed over, the way a model literal does.

Two instances of one union are two declared tag sets.
`tests/suite/generic_union_option.orb` builds `Option<int>`, `Option<string>`
and `Pair<int, string>` from two declarations in one program and exits 0, and
`tests/std/test_option.orb` builds the same instances when the union arrives
through an `import` -- the position the module needs. The instance is registered
once per argument list, in both the checker and the builder, and a payload row
is substituted by `modelSubstitutedType`, the function the generic model already
used.

What is refused is the case with no written type at all. `val x = Option.None`
answers `E1006`, and `tests/negative/n118` pins the text:

```
error[E1006]: 'Option.None' carries no payload, so nothing in this expression
says which instantiation of 'Option' it is and no position writes a type for it
either.
```

Guessing the first instance that declares `None` is the trade this repository
refused for generic models, and the emitted C says why: `generateRouteTypeDecls`
names the tag constant after the instance (`Option_int_TAG_None`), so a guess
would hand a program the tag of a type it never wrote.

## `std/` is 21 modules; the six deleted ones are not coming back

**21 modules, and all 21 compile into one binary.** Verified:
`tests/std/test_imports.orb` imports every one of them into a single program
and calls into each -- except `std/sys/http/client.orb`, which wants a network --
and it passes. Two modules joined it on 2026-11-02: `std/option/option.orb`,
when the generic union landed, and `std/sys/arena.orb`, which had never been
merged with the rest. Its calls are also covered by
`tests/std/color_smoke.orb` and `examples/std_imports.orb`. `tests/std/` is 24 files and runs
24/24 green.

`std/` was 20 modules before `option` landed. **Six were deleted, and the reason
was measured**:
each was a function that returned a value and was not computing it:

| deleted | why it had to go |
|---|---|
| `std/sys/crypto/hash.orb` | `fnv1aHash` was `1469598103 + data.len()`, so `fnv1aHash("hello") == fnv1aHash("hellp")` was **true**. `generateKynxToken("user42")` derived a security token from the *length* of the seed. |
| `std/sys/bytes/buffer.orb` | `appendByte` stored nothing, and `readAt` returned 1/0 and never returned the byte. `writeU16LE`/`writeU32LE` cannot be repaired either: a NUL byte vanishes from a string, measured — `from_char(65) + from_char(0) + from_char(66)` is length 2. `std/bytes/bytes.orb` already owns a working version. |
| `std/sys/net/socket.orb` | There is no socket API anywhere in the language or the runtime. `bindAddress` returned `true` for a valid port on a socket whose `fd` is 0, i.e. stdin. |
| `std/sys/io/io_threading.orb` | No thread primitive exists in the lexer or the runtime. `createPool` set `is_active: true` and `dispatch` incremented a counter. |
| `std/core/memory.orb` | `alloc` returned a null pointer and `free` was a no-op. |
| `std/core/result.orb` | `result` is already a builtin with `ok`/`err`. An unparseable shadow of a working builtin. |

**Nothing is quarantined today.** `std/quarantine/` holds no module, and its
README keeps the convention for the next feature the language cannot express.
Both files that ever sat there are shipped modules now.
`bitwise.orb.quarantined` was the counter-example to the rule below: a syntax
slip (`val` as a parameter name), not a missing feature. It is
`std/sys/bytes/bitwise.orb` again, with `tests/std/test_bitwise.orb` over the
vectors its header published. `option.orb.quarantined` was the real case: a
generic tagged union, refused by the checker until the substitution existed. It
is `std/option/option.orb` since 2026-11-02, and `tests/std/test_option.orb`
covers the positions that write an instance.

They are not `.orb` on purpose: `.orb` is the toolchain's marker for
loadable source. A file the parser cannot read breaks
`orbit fmt --check std` on every run and can only be `import`ed to
produce a parse error. A quarantined module is not deleted because
deleting loses the only written record that the feature was wanted. The
git history alone does not say *which* feature or *why* it is
impossible. `std/quarantine/README.md` has the convention and the
"what does not belong here" list.

`std/fs/file.orb` creates directories (`mkdirAll`, parents included, true
when the directory is already there) and walks a tree. `std/string/string.orb`
parses a float (`parseFloatChecked`, canonical decimal form only, with a
diagnostic instead of `atof`'s silent prefix read). Both are pinned by
`tests/std/test_fs.orb` and `tests/std/test_string.orb`.

`std/json` parses strict JSON into typed values: `parseJson` answers `err`
for malformed input rather than a partial document, and the `json*` getters
read ints, floats, bools, strings, nested objects and indexed arrays. It is
pinned by `tests/std/test_json.orb`. `Option` was the one type the tree named
and could not have; it is `std/option/option.orb` since 2026-11-02. The modules
that claimed the rest are gone, and
[LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#stdquarantine-specified-not-implemented)
names what the standard library does not provide.

## A list carries an element type now, and the checker enforces it

This entry used to be a description of a hole: eight programs that segfaulted
or silently misbehaved. The hole is closed for the receivers the checker can
name. Annotations, literals, pushes and reads are all compared while compiling
([`E1005`](ERROR_CODES.md#e1005--call-argument-type-mismatch) at calls, [`E1006`](ERROR_CODES.md#e1006--bad-type-name-or-binding-mismatch) at pushes, reads and bindings). An empty `[]` plus
pushes is typed by first-push-wins. `int` widens into `list<float>`, but the
reverse is refused. The before/after table was the fix's own evidence and now
lives in git history with it. What is left is a different and smaller hole:

### What is still untyped

- **A `list` parameter declared without its element.** `fn read(xs: list, i: int)`
  has nothing to check a read against, and that spelling stays lenient on
  purpose, the way `unknown` is. Dynamic values cannot be refused
  without breaking code that works. The crash it used to hide is closed
  ([F-0009](ERROR_CODES.md#f-code-index), fixed): generic functions fix the
  element per call site and `tests/negative/n39_list_parameter_has_no_element_type.orb`
  pins that the incoherent call is refused. A model field is no longer in this bullet:
  `model Bag { xs: list<string> }` parses, because `parseModelDecl` reads a field
  type through `parseTypeName`, and a read through it is typed by the field's
  declaration.
- **An element this pass could not type.** `unknown` on either side is accepted,
  as everywhere else in the checker: an unknown is an inference gap, and
  refusing it would turn every gap into an error at every use.
- **A model or a union as the element.** `list<Point>` is checked for
  pointerness and nothing more. The fields of the value are not checked against
  the model's declaration here.
- **A heterogeneous list.** Not expressible in this list, and that is
  a decision about the representation (one boxed element per slot) rather than a
  gap in the check. See
  `tests/negative/list_mixed_element_kinds.orb` for why a boxed element would
  still not make `getOr(l, 0, "d")` legal.
- **The runtime refusal is still the backstop**, and it is still reachable -
  the field case above is the reachable one. It is no longer reachable by any
  push the front end could type, which is the intended end state: a diagnostic
  beats an `exit 2` with no line number.

### An object field read is lowered from the writes in the reading function

`{ "a": 1 }.get("a")` no longer lowers to a list read. It reads the field the
same way a dynamic object is written: the emitter picks the getter from the
setter that wrote that key, so an int field reads back an int, a string field
a string, and a list field a list. That scan only sees the writes in the
function the read is in.

A read whose declared type names one of the kinds an object field holds
(`int`, `float`, `bool`, `string`, `object`, `list`) carries that kind to the
emitter on the read itself, as `IRInstruction.fieldKind`. So
`val ratio: float = o.ratio` reads `0.5` and `val v: int = o.get("missing")`
answers `0`. A key that is absent is not a mismatch, and every typed getter
already answers the zero of its kind for one. The scan still wins wherever it
has an answer, so a same-function literal read is lowered exactly as before.

A read with no declaration is refused, not guessed. Both of these exit 1 from
`orbit check`, with the field named and the fix spelled out:

```orbit
val o = make()
val r = o.ratio          // object field 'ratio' has no known type in fn 'main'
print("${o.deep.x}")     // object field 'deep' has no known type in fn 'main'
```

The message asks for the declaration that supplies the missing answer:
`val deep: object = o.deep`. The value model is one machine word with no tag,
so at run time a dynamic field's kind is not recoverable, and a getter chosen
by guessing would read the wrong width. A tagged value model is the change
that would remove the requirement.

## 16.5% of instructions are `unknown`, and every one of them says so

`scripts/unknown_census.py`, run on 2026-11-03 over 212 files and 105,554
instructions. The ratchet baseline (`scripts/baselines/unknown_count.json`)
only lets the numbers fall, so this is the measured state:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 17,388 | **16.5%** |
| ...with no diagnostic at all | 0 | **0.0%** |

Every `unknown` instruction carries a diagnostic. Five lowering diagnostics
fire exactly once per instruction they make `unknown`, and each count equals
the opcode it annotates: [E2001](ERROR_CODES.md#e2001--unknown-identifier-frontend)
(unknown identifier, 7,663 loads), [E2002](ERROR_CODES.md#e2002--incompatible-binary-operands-frontend)
(binary operands, 963), [E2003](ERROR_CODES.md#e2003--invalid-unary-operand-frontend)
(unary operand, 0), [E2004](ERROR_CODES.md#e2004--untypable-member-read-frontend)
(member read, 4,560) and [E2005](ERROR_CODES.md#e2005--untypable-call-result-frontend)
(call result, 4,202). Their sum, 17,388, is the whole unknown count. The five
sites are `compiler/tir/lower.orb:417`, `:430`, `:438`, `:451` and `:489`, and
each sits on the branch that emits the instruction.

The rate fell from 29.1% to 20.3% on 2026-11-02 because the reader stopped
guessing by name. `declaredReturnType` (`compiler/tir/lower.orb:72`) answers a
call from the function the file itself declares, so the `call` class fell from
6,756 to 4,259; a `val` bound to such a call carries that type into every later
load, and so does a `var x = ...` re-bound by `x = ...`, which the lowering now
writes as a `bind` instead of giving up on. What the table still cannot answer is a call into another file: the lowering
sees one module's declarations. `len`, the runtime builtins and a short list of
names written into this file cover those, and 4,202 calls stay untyped.
The same boundary shows on the load side: the frontend refuses `builder.orb`
with an unknown identifier for `initIRModule`, which `compiler/ir/ir.orb:290`
declares. Sorting the loads by name is a census line now: the probe prints one
`NAME` per distinct E2001 message and the driver sorts each identifier by where
a definition of it lives. Measured 2026-11-04 over the same corpus, 3,203 of the
7,663 read a name the file itself declares, and the five largest of those are
`f`, `instr`, `t`, `n` and `cbTop`. 2,431 read a name from a file this one
imports, 1,754 a name declared elsewhere in the corpus, and 275 a name no corpus
file declares, led by `NULL` with 82. The four buckets sum to the E2001 count,
which is the check the sort carries. The variable table is the largest class
left, not the module boundary.

The same table answers the *load* of a callee name, and that one was worth more
than the type: `tirCanonical` prints nothing when any instruction is `unknown`
or any diagnostic has severity `error`, so a file whose functions were only
partly readable printed no canonical TIR at all. `x = take(x + 20)` now reads
`load int take` and `call int`, and `tests/frontend/assign_statement.orb` pins
the text. Guard the answer: `declaredReturnType` returns "" for a name the
program does not declare, and assigning that over `"unknown"` makes E2001 stop
firing for every undeclared identifier -- the census then read 11.0% and the
number was false. `tests/frontend/undeclared_callee.orb` keeps that from coming
back by requiring the suppression to stay.

The second row used to read 11,491 and this heading used to say 45.5% of the
unknown was silent. `unknown_census.py` computed the number by subtracting
three of the five codes -- `unknown - (E2001 + E2002 + E2003)` -- so `call`
and `member`, the two largest classes, were counted as unreported while the
same run printed E2004=4,821 and E2005=6,756 in its own diagnostic table.
The compiler did not change. The measurement was the script's arithmetic, and
the document quoted it. See the 2026-11-01 entry in [CHANGELOG.md](CHANGELOG.md).

Separately, [E3001](ERROR_CODES.md#e3001--expression-cannot-be-lowered-frontend) "expression cannot be lowered to TIR:
<node>" fired 669 times on this corpus, down from 9,233. It is not in the
unknown total because there is no instruction to type.

The number fell by itself being named. `astNodeKind`
(`compiler/tir/lower.orb:323`) puts the node's own class in the message, and the
census prints the tally (`unknown_census.py`, "What the front end gives up on, by
node class"). Fourteen of the classes the table first printed turned out not to
be capability gaps at all, and each was fixed by reading its count.

`Empty` appeared 5,045 times: `lowerStatement` handed every statement it did not
recognise to the *expression* reader, and an empty statement has no instruction
to emit. It lowers to nothing. `Assignment` in statement position appeared 3,137
times for the same reason; a rebind is the `bind` a `val` already emitted, so
`x = take(x + 20)` lowers now. `MemberAccess` appeared 414 times as a write
through a place, and `d.x = 2` emits `store_field`. That one is conditional: the
write lowers when the place's own value is typed. The alternative is to emit a
member read this pass cannot type, which trades a declared give-up for an
`unknown` instruction -- and an `unknown` suppresses the file's canonical text
exactly as the give-up does, while also raising the number the ratchet holds. A
chained place (`tok.line = 5` under a receiver it cannot type) stays a give-up,
and 211 of them say so today (216 on 2026-11-02). Since 2026-11-03 the table
answers more of those hops: a field declared with another model's name is typed,
and `o.i.n` reads both hops.

`xs[i] = v` is the same write on an index, and it emits `store_index unit <container>
<index> <value>`. The container's own type is the condition, as it is for the field
write: 22 of these write positions were give-ups and 5 stay that way under a
receiver this pass cannot read. The *read* `xs[i]` stays a give-up (8 cases),
because a load would have to say what it loaded and the pass keeps no element
table.

`Point { x: 0, y: 0 }` is a construction with the same problem and a written
answer: 50 model literals gave up, and the name bound to one loaded back
`unknown` at every later use. It emits `construct Point 2 x v0 y v1` now -- the
type the source wrote, the field count, then each field and its value -- and the
reader of types gives the same string, which is the half that removes the loads:
73 of them stopped being `unknown`. A generic literal keeps the bare name the
program wrote, not the `Box_int` the build mints, because this text reports the
source. Four writes through a place lowered as a side effect (`MemberAccess` 216
to 212): their receiver was one of those literals, and it used to be unreadable.

`return ok 200 "ready"` is another with a written answer: 8 of them gave up as
`ReturnOk`, because the statement reader knew `return <expr>` and not the `ok`
form. It emits `result_ok result 200 v0` and then `return unit v1` -- the name
the build IR gives the wrapper, the status the source wrote, and `void` when the
`ok` carries no payload at all, because the parse keeps the empty expression
rather than dropping it.

`d.x` is the largest single source removed on 2026-11-02, and it came from one
question the pass had never been asked: what type does this file declare for
that field. `typeOfExpression` answered `int` for `len` and `unknown` for
everything else, so every member read entered the count as `unknown` (E2004,
5,389 of them). The program's own `model` declarations are collected before any
body is lowered, and a field declared `int`, `string`, `bool` or `float` answers
its written type. On 2026-11-03 two more field types became answers: one declared
`list` or `list<string>` answers `list`, the same claim the pass already makes
for a list literal, and a field whose type names another model this file
declares answers that written name, so `o.i.n` reads both hops. 1,050
instructions left the unknown count with the first step, and the rate moved from
19.3% to 18.3% (193 per mille to 183). 4,560 reads are still untyped: a model
declared in another file, a union, and one element of a list -- the element kind
is not claimed, because this pass keeps no table for it.
`tests/frontend/field_read.orb`, `tests/frontend/nested_field_read.orb` and
`tests/frontend/list_field_read.orb` pin the three answered field types;
`tests/frontend/crossfile_field.orb` pins that an imported name is not one of
them.

`[1, 2]` was the fourth: no rule for a list literal, so the elements were never
lowered and the name bound to one loaded back `unknown` -- the reader of types
and the lowerer disagreed about what the value was. 412 give-ups, 780 unknown
identifier reports, and the canonical text suppressed in every file that used
one. It emits `list` now and both readers answer `list`; the element kind is not
claimed, because the pass keeps no table for it.

The fifth was `fn shout() { return }`: a bare `return` has no value to lower, so
it reached the expression reader and reported `Empty` -- 279 times -- and the
error suppressed the file's canonical text. It emits `return unit void`, with
`void` written rather than left empty so every `instr` line keeps its fields.
`break` and `continue` were the sixth and seventh: jumps to the enclosing
loop's exit and condition blocks, which nothing had been threaded to tell them,
so they reached the expression reader as `Break` (91) and `Continue` (26) and
suppressed the file's text. The two targets ride on the statement lowering now.
A `break` outside a loop has no block to name and stays a give-up that says so.

`For` was the eighth: the statement lowering had no arm for a loop at all, so
every one of the 46 reached the expression reader and suppressed its file's
text. `for x in 0..n` counts an int between the bounds, so it lowers to the `while`
form plus an increment block, and the increment is where a `continue` lands --
jumping to the condition with the counter unchanged repeats one item forever.
`tests/frontend/range_loop.orb` pins both loops and an index binding.
20 of the 46 iterate a value whose element type this pass does not keep, and 4
name an enclosing loop for a labelled `break`; each message says which. Emitting
the list path anyway would bind the item to `unknown`, suppressing the same text
and raising the count the ratchet holds, so it stays a give-up and
`tests/frontend/list_iteration.orb` pins that.

Interpolation was the ninth. `"count=${n}!"` is three parts -- text, the value
of `n`, text -- and the pass had no rule for the whole literal, so 12 of them
were give-ups that also suppressed their file's text. It emits `interp` now,
answering `string`, with a count of parts and the flag that says whether the
text chunks are taken verbatim or unescaped: that reading is decided at the
build, and copying the unescape rule into this module would be a second answer
to one question. `tests/frontend/interp_parts.orb` pins the text.

`MigrationDecl` and `ConfigDecl` were the tenth and eleventh. A `migrations`
line and a file-scope `config` value (`port 8080`) declare data, so there is no
instruction to emit for them -- the same reason a file-scope `const` lowers to
nothing. They reached E3000 anyway, and E3000 has severity error, which is what
suppresses a file's canonical text: a program with a migration printed no TIR
at all for a declaration that carries no code. `E3000` reads 0 on this corpus
now; its diagnostics row is gone from the table above. A `schedule` stays
refused on purpose: its handler is a body, and a pass that skips a declaration
carrying code has described a file it never read.

What is left of the class list is `Match` 301, the chained `MemberAccess` 211,
`Try` 93 and `If` 30. After them, a `for` over a value with no element type 20,
`IndexAccess` 8 reads and 2 writes, and a labelled `break` with no target 4.
Lowering a loop lowers its body too, so the absolute count moves both ways and
the rate is what to read: 17,388 unknown over 105,644 instructions on
2026-11-03, against 20,005 over 103,333 on 2026-11-02 and 25,489 over 86,942 at
the start of that day.
The ratchet reads the rate. Worst file by share of unknown instructions:
`compiler/front/parser.orb`. Re-run the census rather than trusting these numbers.

Two tools, and the difference matters. `unknown_census.py` is the
**measurement** and never fails anything. `scripts/unknown_ratchet.py`
is the **gate**: it reads the census output, compares two of the
numbers against a committed baseline in `scripts/baselines/`, and
fails if either went *up*. It does not fail because the count is high -
16.5% is the number the type work has to be scoped against, and a
zero-bar gate is a gate everybody deletes. Run on 2026-11-02, after the
baseline moved down to the measured numbers:

```console
$ python scripts/unknown_ratchet.py --compiler <orbit> --cc gcc
  unknown_per_mille               168  baseline    168  unchanged
  silent_per_mille                  0  baseline      0  unchanged
Finished unknown-count: 168 (baseline 168, ratchet holds)
```

What the second number holds now is the one-to-one tie above. An opcode that
starts producing `unknown` without a diagnostic, or one of the five that stops
firing once per instruction, moves it off zero and the gate fails.

Raising a baseline is a deliberate act: `--write-baseline` refuses to
move a number up unless `--allow-regression` is also passed. So the
count can only go down, which turns "do not regress this" from a rule
people follow into a property the build enforces.

## The frontend gate is 27/27

`scripts/frontend_gate.py` runs 27 fixtures and all 27 pass (two of
them, `syntax_error.orb` and `unresolved_type.orb`, could not build for most
of this cycle, and both missing imports are fixed). `print_pipeline.orb` pins
`call void print`, which is what made `orbit frontend examples/hello.orb`
fail before. Five pin an absence of output rather than a text, and the gate
owns that list in `EMPTY_EXPECTATIONS`: for a suppressed file a golden would be
the wrong artifact. 22 `.tir` goldens sit in `tests/frontend/expected/`.
`interp_parts.orb` pins the interpolated string, and its
hole is written `$` because a fixture cannot embed `${`: the lexer that reads
the fixture's own literal would interpolate it, so the marker is decoded in the
gate's test plumbing rather than as a language escape.
`crossfile_field.orb` is the fifth and the boundary case: a field whose type is
a model declared in another file keeps E2004, and the fixture prints only when
the refusal names that code, so an input that stopped reaching the member-read
rule cannot pass on a silent match.

## `lib/net.orb` is gone

`lib/net.orb`, `lib/sys/linux.orb` and `lib/sys/windows.orb` were an
unspecified socket-wrapper sketch nothing imported (its event loop was
`while running { ... running = false }`). Deleted, not quarantined:
`std/quarantine/` is for specified features the language cannot express yet,
and no document specifies a socket API. `std/sys/arena.orb` (real, used by
`examples/` and `tests/std/`) was not touched.
