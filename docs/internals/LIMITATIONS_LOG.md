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

`doctorCodePart` (`compiler/tools/doctor.orb:4050`) is what changed. It quoted the
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

`scripts/doctor_gates.py doctor` scans the directories that must be clean, and when one
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
Finished negative: 128/128 pass (0 known defects still accepted)
```

One hundred and twenty-eight programs: every one must be rejected and is. The last one
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
this reason ([F-0004](internals/DEFECTS.md#f-code-index)). A helper in the wrong side of the graph was an unresolved
call, which is not an error: `orbit check` stayed clean and the C compiler
rejected the output with a name it had never been given.

The tests that pin all four are `tests/suite/model_field_owner_typing.orb`,
`generic_nested_argument.orb` and `parameter_type_fallback.orb`.

What replaced the list, in the order the work was done:

| what used to happen | what happens now |
|---|---|
| `.at()` on a list read a byte of the list pointer and answered 0 | `.at()` and `.get()` both do the right thing, on ints and on strings |
| a call argument's type was never compared with the parameter's | [`E1005`](LANGUAGE_REFERENCE.md#e1005--call-argument-type-mismatch), naming the parameter and both types |
| an undeclared identifier printed a stack address | *Undeclared identifier: nothing in scope declares it* |
| a call with the wrong arity dropped the extra arguments | *Wrong number of arguments to f: it takes 1, got 3* |
| a model constructor accepted the wrong argument types | [`E1003`](LANGUAGE_REFERENCE.md#e1003--bad-member-read-bad-construction-bad-print-arity), naming the field and both types |
| `1e2` was the integer `1`, `0b101` was the integer `0` | both are literal values; an exponent is always a float |
| `(0-7)/2` was `-4` and `(0-7)/3` was `1431655763` | `-3` and `-2`, C semantics, pinned by `div_mod_signed.orb` |
| `9223372036854775808` silently became `-9223372036854775808` | *integer literal does not fit an orbit_int* |
| `s.at(99)` answered 0, which is the NUL byte | [`E1002`](LANGUAGE_REFERENCE.md#e1002--literal-index-out-of-range), naming the index and the length |
| `val v: widget = 3` was ignored | [`E1006`](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch), and a capitalised unknown type is refused too |
| `val n: Int = 1` reached gcc as `Int*` | [`E1006`](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch), with the note that types are lower case or declared |
| `m.nonexistent`, `s.radius`, `n.nothing` died in the C step | [`E1003`](LANGUAGE_REFERENCE.md#e1003--bad-member-read-bad-construction-bad-print-arity), and the receiver's own members are the only ones |

Two of those deserve a note about *how*, because both were the same mistake
wearing different clothes.

**A check that only knows one table is a check that guesses.** [`E1006`](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch) refuses
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
[`E1003`](LANGUAGE_REFERENCE.md#e1003--bad-member-read-bad-construction-bad-print-arity) with a line and a column in the user's own file.

The mechanism underneath is described in
[the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag),
and the measurement that says how much of the front end is still untyped is
[below](#01-of-instructions-are-unknown-and-every-one-of-them-says-so).


## A `try` binding annotation is checked where the payload is written

**Closed 2026-11-12.** Two refusals close the hole this section measured.
`tests/negative/n132_result_ok_payload_mismatch.orb` pins `ok(5)` in a
`-> result<string>` body, and `n133_result_composed_payload.orb` pins a
`-> result` wrapper whose callee answered a payload. The bare `result` itself
was still a wildcard at that point. The history below is the measurement that
led here; the paragraphs that say the hole is open describe the tree before
the fix.

**Closed 2026-11-13.** A bare `result` no longer accepts a non-result:
`checkCompatibility` answers `compatTypeBase(got) == "result"` for that arm.
`n134` pins the refusal, `Parameter 1 of take is declared result but the
argument is int`, and `result_parameter.orb` pins the valid form.

**Closed 2026-11-13, a refusal stays one diagnostic.** A refused declaration
used to return without declaring the name, so the read after it reported the
name undeclared and counted a resolution miss. The `main`, generic and extern
value refusals answered `unknown`, so the call after one reported a second
error: not a function. All four leave the poisoned spelling now. It fits every
expected type and is a type nowhere, so the refusal remains the whole output.
`tests/negative/n135_arena_refusal_one_diagnostic.orb` and
`n136_main_value_refusal_one_diagnostic.orb` pin the count with
`one-diagnostic:`, and neither prints an `UNRESOLVED` line.

`compiler/front/sema.orb:4933` answers a `try` with the payload the callee's signature
writes, so the annotation on the binding is compared with what the read yields:

```console
$ cat tryprobe.orb
fn decode(s: string) -> result<string> {
    return ok 200 s
}

fn main() -> int {
    val n: int = try decode("x") catch { return 7 }
    print(n)
    return 0
}
$ orbit check tryprobe.orb
  error[E1006]: 'n' is declared int but the value is string.
    --> tryprobe.orb:6:9
```

`decode` carries a `string`, `n` is annotated `int`, and `print(n)` reads that
pointer as an integer. The mechanism is already written down at
`compiler/front/sema.orb:4838`, which blames it for `ok 200 system.uptime()`
reaching the C backend with an int where a string pointer belongs. The fix there
named a receiver type; this site has no receiver to name, because the payload is
written nowhere, and `tests/negative/n123_try_annotation_payload.orb` keeps the refusal.
Before 2026-11-05 the same arm answered `unknown` for every `try`, and the compatibility
rules accept `unknown` for anything, at `compiler/front/sema.orb:1165` and `:2140`: the
probe above built, and `print(n)` read a string pointer as an integer.
Two counts of this sentence have been wrong and both are dated rather than hidden: the
first said 51 in 31 files, counting the spelling wherever it appeared, and the second
said 42 and 0 with a pattern that could not see a payload at all, because the formatter
writes `result < string >` with spaces around the angle brackets. Counting every tracked
`.orb` and skipping comment lines, on 2026-11-05: **67 signatures return a bare
`-> result` and 13 write a payload**, out of 527 files.
**Re-measured 2026-11-10:** **65 return a bare `-> result` and 8 write a payload**,
out of 551 files. The earlier 67 and 13 added up to 80, which is the unfiltered
total: seven `tests/frontend` harness string literals were counted as signatures.
The count moves with the corpus, so this line is the date to trust, not the one
above it.
**Re-measured 2026-11-12:** **73 return a bare `-> result` and 17 write a
payload**, out of 564 tracked `.orb` files. The two refusals above are in the
corpus.

The half this section measured open was the bare `-> result` signatures; the refusals below closed it on 2026-11-12. For a bare `-> result` the read's type is the
annotation itself: `compiler/ir/builder.orb:3140` retypes the unwrap register to it and
`compiler/emit/c_backend.orb:4383` emits the cast for `int`, `bool`, `string` and `list`.
Nothing conflicts with the annotation, so there is nothing to check; the program is wrong
only when the value `ok` put there differs from what the caller asks, and that is a fact
the signature never wrote.

The same missing spelling is why `try` expressions gave up in the frontend pass.
`std/convert/codec.orb` now writes `result < string >` on the two decodes, and 19 of
those give-ups moved: 8 stopped being give-ups at all, and 11 became the next class
-- `a handler that falls through needs a merge value`, which the pass does not model. That class prints no row on 2026-11-04: a `try` in statement position reads no value, and all 20 of its cases were that.
Closing the spelling exposes the class behind it, which is how every number here has
fallen. 17 in `tests/std/test_json.orb` and 15 in `tests/std/test_string.orb` could not be
spelled then, because `ok` admitted only a string or an object as its payload, so
`parseIntChecked` returning `result < int >` was refused -- `ok response body must be a
string or an object, got int`. That restriction was a limitation of its own, not a missing
annotation, and it is gone: the guard reads the base type of the declared return now, and
both files write their payloads. The probe above is
not a `tests/negative` case: that gate pins a program that fails to compile, and
this one compiles.

Before the fix, the hole was open on the shipped compiler and was run on 2026-11-10. `ok(5)` inside
`fn wrong() -> result` checks clean, and `val v: string = try wrong() catch {
return 7 }` checks clean too, `orbit build` compiles it, and running the binary
faults: `[ORBIT RUNTIME CRASH] ExceptionCode 0xC0000005`, exit 139, because the
int is read back as a string pointer. No `tests/negative` case pins a refusal,
because there is no refusal to pin -- the bare `result` is compatible with every
payload at `compiler/front/sema.orb:2148`, and `checkCompatibility` returns true
whenever the wanted type is `result`.

One route to closing it was tried and is falsified here, because the plan said
the block was in the checker. It is not only there. Adding a compatibility rule so
a bare `result` value satisfies a `result<string>` signature makes
`orbit check` accept the program, and the C step then refuses the emission:
`r_2 = (orbit_string)(r_0.value)` reads `.value` off a `void*` local, because
`compiler/emit/c_backend.orb` has no hoisted type for a declared `result<T>`
return. Typing `ok(x)` from its argument was also tried; it answers
`result<string>` everywhere and breaks 11 programs of the 125 in `tests/suite`,
and the checker already restricts the body of `ok` to a string or an object when
the signature writes a payload. So the change is an emission change first, and the
checker rule is the smaller half. Both halves landed on 2026-11-04 in `df40323`:
the builder spells the IR type of a result `result` whatever the annotation says,
and `checkCompatibility` admits a bare `result` value against a signature that
names a payload. What is left in this section is the restriction on `ok` -- a
payload of `int` or `float` cannot be written -- and the unchecked annotation the
probe at the top of the section still demonstrates: writing a payload on a
signature is possible now, but `-> result` with no payload is still compatible with
every value, so `val v: string = try wrong()` stays accepted.

The size of the hole was countable without changing anything. 47 sites in the corpus
bind a `try` with a written annotation (`val d0: string = try base64Decode(...)`),
and 41 of them call a function that declares the bare `result`. None of the 47 can
be compared with a payload, because no function declares one. The annotation is
therefore decoration in every one of them today, and the 6 left are annotations
whose callee this scan did not resolve.

Before the fix, writing the payload at the declaration did not work either, and the reason was
the checker. Spelling `std/convert/codec.orb:146` as
`fn hexDecode(s: string) -> result<string>` makes `orbit check` refuse the file:

```console
Semantic error: Return type mismatch: expected result<string>, got result [in hexDecode]
```

The body returns `ok(out)`, and `compiler/front/sema.orb:4628` gives that call a bare
`result`. A declaration cannot be more precise than the constructor expression the
checker hands it. The two rules have to move together -- `ok` and `err` typed from
their argument, then `try` typed from the declared `result<T>` -- and neither is a
rule the frontend pass can take on its own. That is why this section stayed open until 2026-11-12.

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
`orbit_string`. The save writes the part as a byte range, so a five-byte
part holding `a\0bcd` lands as five bytes. Pinned by
`runtime/test_upload.c`.

## An editor gets checks on save, not a language server

The VS Code extension in `editors/vscode/` registers syntax highlighting and runs
`orbit check <file>` on save, and that is the whole editor story. There is no
`orbit lsp` subcommand and no server behind one.

**Corrected 2026-11-10:** the subcommand exists. `compiler/host/main.orb:501`
dispatches `lsp`, `compiler/tools/lsp.orb` answers `initialize`,
`didOpen`/`didChange` with the diagnostics `orbit check` gives, `shutdown`
and `exit`, and `docs/COMMANDS.md:32` documents it. The half above that
still holds is completion and navigation, which the server does not answer.

A minimal server needs the process's own standard input. The runtime exposes
argv, `exec`, the environment, cwd, temp and the clock, and since 2026-11-07
three reads of stdin: `orbit_stdin_read_line` (one line, CR dropped),
`orbit_stdin_read_bytes(n)` (exactly n bytes, looping over short reads) and
`orbit_stdin_at_end` (`feof`). `runtime/test_stdin.c` drives all three through a
file handed to `stdin`, so the same four assertions run on both hosts. On top of
that read, JSON-RPC needs a Content-Length framer; `std/json/json.orb` already
parses the bodies.

A server written in another language would bring back the dependency this
project exists to remove. The order is the two reads, a gate that feeds them,
then a server that answers `initialize`, `textDocument/didOpen` and
`textDocument/didChange` by running the checker and publishing its diagnostics.
Until then, save-time `orbit check` is the supported path, and it is what the
extension runs.

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
record in [Resource and Energy Measurement](internals/ENERGY.md) enforces this.

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
`CTRL_BREAK_EVENT` (`compiler/emit/route_runtime.orb:607-614`, registered at
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
after the workers join (`compiler/emit/route_runtime.orb:815`). `cluster down`
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
now: `scripts/admission_gate.py live` starts a second server against the occupied
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
| `Box(1)` | [E1003](LANGUAGE_REFERENCE.md#e1003--bad-member-read-bad-construction-bad-print-arity). The positional form has an argument and no way to call it an int. (n47) |
| `fn take(b: Box<int>)`, `-> Box<string>` | Supported. The written argument names (and creates) the instance. |
| `fn take(b: Box)` | [E1006](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch). Nothing to infer from before the value exists; write the argument. (n51) |
| `model Box[T: int]` | Parser error. A constraint is a promise about an argument this language infers, so there is nothing to hold it to. (n53) |
| `model Phantom[T] { id: int }` | [E1006](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch): no field's declared type mentions `T`, so there is no value to take the argument from. `void*` would compile, and would be a lie about the model. (n52) |
| `Same { a: 1, b: "s" }` where `model Same[T] { a: T, b: T }` | [E1006](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch). `a` fixes `T` at `int` and `b` is then checked against it. (n50) |
| `model Box[T] { v: list<list<T>> }` | `T` is not determined. Only a field declared `T`, or a `list<T>` whose value is a list literal, fixes an argument. |
| `Option.None` where no position writes a type | [E1006](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch): `'Option.None' carries no payload, so nothing in this expression says which instantiation of 'Option' it is and no position writes a type for it either.` (n118) |

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
`variantPayloadAt(sema, owner, variantName, idx)` (`compiler/front/sema.orb:776`)
-- and a bare pattern resolves through the scrutinee's type in `bareVariantOwner`
(`compiler/ir/builder.orb:2415`). The constructor macro carries both names:
`val mvMacro = cUserName(mvType.name + "_" + mvName)`
(`compiler/emit/c_backend.orb:100`) where it read `cUserName(mvName)`. The two
programs that would have collided link and run, which is what the name is for.

What is refused is the case with no owner to read. `val p = Body(3)` with both
unions in scope answers
[E1011](LANGUAGE_REFERENCE.md#e1011--variant-name-belongs-to-more-than-one-union),
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
| `std/sys/crypto/hash.orb` | `fnv1aHash` was `1469598103 + data.len()`, so `fnv1aHash("hello") == fnv1aHash("hellp")` was **true**. `generateAdmissionToken("user42")` derived a security token from the *length* of the seed. |
| `std/sys/bytes/buffer.orb` | `appendByte` stored nothing, and `readAt` returned 1/0 and never returned the byte. `writeU16LE`/`writeU32LE` cannot be repaired either: a NUL byte vanishes from a string, measured — `from_char(65) + from_char(0) + from_char(66)` is length 2. `std/bytes/bytes.orb` already owns a working version. |
| `std/sys/net/socket.orb` | No `extern fn` in `std/` reaches a socket, so an Orbit program could not open one. `bindAddress` returned `true` for a valid port on a socket whose `fd` is 0, i.e. stdin. |
| `std/sys/io/io_threading.orb` | No `extern fn` in `std/` reaches a thread, so an Orbit program could not start one. `createPool` set `is_active: true` and `dispatch` incremented a counter. |
| `std/core/memory.orb` | `alloc` returned a null pointer and `free` was a no-op. |
| `std/core/result.orb` | `result` is already a builtin with `ok`/`err`. An unparseable shadow of a working builtin. |

The two rows above said "no socket API anywhere in the language or the runtime"
and "no thread primitive exists in the lexer or the runtime" until 2026-11-04. Both
were wrong as written. `runtime/socket_compat.h:27` declares
`orbit_socket_close`. `runtime/thread_pool.c:45` declares
`orbit_thread_t`. `compiler/emit/route_runtime.orb:10` emits
`#include "thread_pool.c"` into every generated program. What does not exist is an `extern fn` in `std/`
over them: `std/sys/http/client.orb` exposes `orbit_http_client_fetch` and
`std/sys/proc/process.orb` exposes `system_pid`, `system_env`, `system_os_exec`,
`system_os_exit`, `orbit_os_argc` and `orbit_os_argv`, and nothing exposes a socket
or a thread. The missing thing is therefore a dozen declarations and a wrapper, not
a primitive built from scratch, and the deleted modules' reason is that no program
could reach the mechanism -- which was true of `bindAddress` reading fd 0 and of
`dispatch` counting to itself.

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
([`E1005`](LANGUAGE_REFERENCE.md#e1005--call-argument-type-mismatch) at calls, [`E1006`](LANGUAGE_REFERENCE.md#e1006--bad-type-name-or-binding-mismatch) at pushes, reads and bindings). An empty `[]` plus
pushes is typed by first-push-wins. `int` widens into `list<float>`, but the
reverse is refused. The before/after table was the fix's own evidence and now
lives in git history with it. What is left is a different and smaller hole:

### What is still untyped

- **A `list` parameter declared without its element.** `fn read(xs: list, i: int)`
  has nothing to check a read against, and that spelling stays lenient on
  purpose, the way `unknown` is. Dynamic values cannot be refused
  without breaking code that works. The build names no element kind for that
  parameter either: `xs.get(i)` through it emits `list_get` with `elemKind` 0 and
  a `void*` destination register (measured 2026-11-05). The crash it used to hide is closed
  ([F-0009](internals/DEFECTS.md#f-code-index), fixed): generic functions fix the
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

## 0.01% of instructions are `unknown`, and every one of them says so

`scripts/measure.py census`, run on 2026-11-08 over 215 files and 149,684
instructions. The ratchet baseline (`scripts/baselines/unknown_count.json`)
lets the two rates fall and the instruction total only grow -- a rule that makes
the pass give up earlier lowers the total, not the rate -- so this is the
measured state:

| | count | share |
|---|---|---|
| instructions the front end types `unknown` | 3 | **0.0%** |
| ...with no diagnostic at all | 0 | **0.0%** |

A `match` arm that binds a payload lowers since 2026-11-06: the files that
printed no TIR for one now print theirs, so the measured corpus grew from
111,537 instructions to 147,001. The rate fell from 2.46 to 2.09 per mille in
the same change; the absolute count rose with the denominator, 275 to 307.
On 2026-11-07 a written `list` began to name its element, and the count fell
to 277 over 146,974 instructions: 15 loads and 15 calls that read through such
a list now carry the element's type. The same day, `orbit lsp` joined the
corpus and raised it to 280 over 147,976. A `val` whose value has no type now
takes its annotation as the binding's type: `val src3: string = sources.get(i)`
promises a type the call does not answer, sema checks the promise against the
value, and the register reads back `string` instead of `unknown`. A list
annotation keeps its element, so `val out: list<DoctorEdit> = []` answers a
`.get`. The count fell to 211 over 148,046 instructions, E2001 from 114 to 48
and E2005 from 100 to 98, and 70 instructions appeared where a statement that
read one of those names lowered and had been skipped. A character read answers
`int` now: this pass typed `s.at(i)` as `string` while the build already typed
it `int` (`compiler/ir/builder.orb:1984`), so every `c - 48` in a lexer-shaped
loop was two unknown operands. The count fell to 173 over 148,122 instructions
and E2002 from 50 to 12. A list binding keeps the element its annotation names:
`val out: list<DoctorEdit> = []` typed its literal as the bare `list`, which
says nothing a later `.get` can answer, and the annotation was read only when
the value had no type at all. The count fell to 116 over 148,142 instructions,
E2005 from 98 to 54, E2001 from 48 to 36 and E2004 from 15 to 14. A local with
no annotation takes the element of the value pushed into it: `val out = []`
writes no element, and every `out.get(i)` after the first push had nothing to
answer. The count fell to 96 over 148,271 instructions, E2005 from 54 to 37 and
E2001 from 36 to 33. A `try` binding reads the same annotation helper as any
other `val`, so `val o: object = try parse(t) catch { ... }` binds `object` and
`val xs: list<int> = try ...` binds the whole list. The count fell to 90 over
148,242 instructions. A bare variant names its union: `Circle(5)` with no type
before the dot is a construction of the one type that declares `Circle`, and
`NoInt =>` in a match arm is a tag test rather than a load of a name nothing
declares. A name two unions share is not guessed at. The count fell to 74 over
148,474 instructions, E2001 from 28 to 17 and E2005 from 36 to 31. A named
model literal writes the argument its model declares -- `Box { v: 1 }` is a
`Box<int>` -- which is the inference the build already made, so `b.v` answers
`int`. A literal that leaves the argument out keeps the bare name. The count
fell to 58 over 148,736 instructions, E2004 from 14 to 1 and E2002 from 12 to
9. `tests/frontend/generic_literal_field_read.orb` held the other branch open as
an empty expectation; it is an emit fixture with its golden now, and it was the
only expectation this work flipped. `s.to_int()` answers `int`, the type the
build and the checker already give it; the count fell to 55 over 148,744
instructions, E2005 from 31 to 30 and E2001 from 17 to 15. A file-scope
`val`/`const` written with a literal is a `#define` in the build, so it emitted
no instruction and a read of it was E2001; the module keeps those names and their
literal's type, and the read is answered. The count fell to 49 over 148,939
instructions, E2001 from 15 to 9. A member call on an `object` answers
`object`, which is the register the build allocates for it; the value model is
one word with no tag, so the callee's name is not the type of what it returns.
The count fell to 39 over 148,946 instructions, E2005 from 30 to 20. A `push`
inside a `while` body refined the local in the body's copy of the bindings, and
the copy died with the loop; the statements after it read the same local, so the
refinement now comes back out -- only that shape, because a name the body
declared is out of scope and an assignment is not a type. The count fell to 27
over 148,984 instructions, E2005 from 20 to 8. An assignment keeps the type the
declaration gave the name: `var ratio: float = 1.5` followed by `ratio = 3` is
still a float, and only a name with no declared type takes the value's. The
count fell to 25 over 148,999 instructions, E2002 from 9 to 7. A member call
naming a declared function answers that function's return type, which is the
builder's default method path; the count fell to 24 over 149,012 instructions
and E2005 from 8 to 7. A `try` with no `catch` propagates: the error path
returns the original result unchanged, which is the `ret` the build emits for
the same source, so the handler is not a give-up. The count fell to 18 over
149,050 instructions. A `match` used as a value lowers the way the statement
form does, with each arm binding the join name and the merge block loading it --
and the corpus grew 286 instructions in the same change, which the ratchet's
third number now records. The count fell to 15 over 149,336 instructions. A
`push` inside an `if` branch or a `match` arm then typed the local after it, the
way a push inside a `while` body already did: all three bodies lower with a copy
of the bindings, so the copy's refinements come back out. The count fell to 10
over 149,371 instructions, E2005 from 7 to 2, the three `.get` reads in
`doctorRun` and the one in `compiler/ir/builder.orb` answered, and
`tests/suite/list_push.orb` came to 0. A generic union's payload then answered
the argument its instance writes. The type table records a union's parameters
the way a model's already did, the tag lookup reads the declaration's base name
so an instance finds its table, and an arm reads each packed payload part and
substitutes it: `Box.Has(n)` under `Box<int>` binds `int`, and `Pair.Both(n, t)`
under `Pair<int, string>` binds `int` and `string`. A binding annotation that
names a declared instance types the value beside it, so
`val p: Pair<int, string> = Pair.Both(3, "three")` carries the arguments the
construction leaves bare. The count fell to 6 over 149,578 instructions, E2002
from 5 to 2, E2001 from 2 to 1 and E3001 from 9 to 4: two matches that could not
find their variant table lower now, and `tests/std/test_option.orb` came to 0. A
`try` handler then kept the loop its `try` sits in, so a `continue` inside it
resolves and the value the `try` is bound to exists; and the reader of an `if`
branch bound the `val`s that branch declares before asking what it answers. The
count fell to 3 over 149,684 instructions, E2002 from 2 to 0 and E2001 from 1 to
0: `tests/suite/result_in_loop.orb` and `tests/suite/if_expression_return.orb`
came to 0.

The three that remain are the floor of this pass, and each is a question another
module has to answer. `Box<T>`'s field `v` read inside `fn get[T](b: Box<T>)`
needs the instance a call site writes, and this pass reads one file's text
rather than every instantiation. `Option.None()` is a construction whose
instance only the binding annotation names, and the call is emitted before that
annotation is read. `doctorClosureRefs` reads a list a callee filled, so the
element kind has to travel from the callee's parameter back to the caller. All
three print a diagnostic and the silent count is 0, which is the property the
census exists to keep.

Every `unknown` instruction carries a diagnostic. Five lowering diagnostics
fire exactly once per instruction they make `unknown`, and each count equals
the opcode it annotates: [E2001](LANGUAGE_REFERENCE.md#e2001--unknown-identifier-frontend)
(unknown identifier, 0 loads), [E2002](LANGUAGE_REFERENCE.md#e2002--incompatible-binary-operands-frontend)
(binary operands, 0), [E2003](LANGUAGE_REFERENCE.md#e2003--invalid-unary-operand-frontend)
(unary operand, 0), [E2004](LANGUAGE_REFERENCE.md#e2004--untypable-member-read-frontend)
(member read, 1) and [E2005](LANGUAGE_REFERENCE.md#e2005--untypable-call-result-frontend)
(call result, 2). Their sum, 3, is the whole unknown count. The five
sites are `compiler/tir/lower.orb:1044`, `:1057`, `:1065`, `:1089` and `:1229`, and
each sits on the branch that emits the instruction.

The rate fell from 29.1% to 20.3% on 2026-11-02 because the reader stopped
guessing by name. `declaredReturnType` (`compiler/tir/lower.orb:135`) answers a
call from the function the file itself declares, so the `call` class fell from
6,756 to 4,259; a `val` bound to such a call carries that type into every later
load, and so does a `var x = ...` re-bound by `x = ...`, which the lowering now
writes as a `bind` instead of giving up on. A call into another file answers
too, since 2026-11-04: `compiler/tir/entry.orb` reads the file's `import` lines,
parses each imported program and registers its signatures and models before any
body is lowered, so `later(n)` in `tests/frontend/imported_signature.orb` emits
`load int later` and `call int` instead of reporting E2001 and suppressing the
file's whole text. Imported bodies stay unlowered: the printed TIR belongs to
the file named on the command line. 104 calls stay untyped, and the census names
what each one called. The ones that remain are methods and callees on a receiver
the pass cannot read, and `unknown` is the answer there, not a gap. The build
records no kind for that container either: measured 2026-11-05,
`orbit build --emit-ir` on
`fn pick(xs: list, i: int) -> int { val v = xs.get(i) return v }` writes
`list_get` with `elemKind` 0 and gives the read's register the type `void*`. So
this pass is at parity with the build, not behind it. Whether to type those
reads was a decision about the language, and it was made on 2026-11-07: a
written `list` names its element (E1012), so a signature can no longer write a
parameter whose element nothing knows. A list built from an empty literal stays
bare until the first push decides, and a read through it still answers `unknown`.
The census sorts the rest by callee, and the split adds up to the E2005 count,
which is the check the table carries. E2005 said only "this call" until 2026-11-04, when the callee joined the
message: a method is not a missing declaration, and the two are not the same work.
Reading them named the largest one -- `.push`, 375 of them -- and a list write
answers `void`, the type the build already gives it, so the call class fell 621 to
226 the same day. `err` 37 and `ok` 13 then went the same way. The checker knows
both by name, and `compiler/ir/builder.orb:389` and
`compiler/emit/c_backend.orb:4622` already answer `result` for them. The name is
not a value to load, so the calls fell to 176 and 75 loads went with them.
`system` went the same way on the same day. The checker resolves that receiver by
name and answers `int` for its ten methods, so the receiver loads as `system` and
`system.uptime()` is `call int`. 38 instructions left the count with it: 27 loads
and 11 calls, and the calls fell to 165.

Sorting the loads by name is a census line: the probe prints one `NAME` per
distinct E2001 message and the driver sorts each identifier by where a definition
of it lives. The probe itself was the last thing holding the old numbers: until
2026-11-04 it lowered each file with `lowerProgramToTir`, which reads only the
text it is handed, so it measured a program the command line never compiles. It
calls the entry point `orbit frontend` calls now. Measured 2026-11-05 over the
112 unknown loads: 104 read a name the file itself declares, led by `fplines` 9 and
`name` 7. 8 read a name no corpus file declares:
`Circle` 2, `Square` 2, `Fast`, `Slow`, `Both` and `taken`. No load reads a name that only a file this one imports declares.
`Token` was 54 of those and `LiteralNode` 21: a model name in call position
constructs the model, so the callee stopped being a value read off nothing. The
buckets sum to the E2001 count, which is the check the sort carries.

The other split says which of them is work. 94 are echoes: the reading
function binds that name, so it is the value bound into it that has no type. The
other 18 read a name that function never binds. Two classes went here and came
back answered: `TokType` was 582 loads of an enum name, and `NULL` was 82 of a
constant the checker already resolves. The payload-less variants of an `enum` and
of a `union` enter the type table and emit `const TokType TokType.EOF`; `NULL`
answers `NULL`, the name the build IR gives it. `tests/frontend/enum_variant_read.orb`,
`tests/frontend/union_variant_read.orb` and `tests/frontend/null_literal.orb`
pin the three answers. A union variant with a payload stays unanswered as a read: it is a
construction that needs its argument, and a constant would invent the value. Called, the
same qualified name answers the type written before the dot.

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

Separately, [E3001](LANGUAGE_REFERENCE.md#e3001--expression-cannot-be-lowered-frontend) "expression cannot be lowered to TIR:
<node>", with the two named refusals the `if` and `match` rules added, fired 270
times on this corpus, down from 9,233. It is not in the
unknown total because there is no instruction to type. On this run the two tallies
read 275 and 270; they are counted from different fields, and their
per-file rows differ -- `compiler/tools/doctor.orb` has 61 untyped instructions
and 29 arms that bind a payload.

The number fell by itself being named. `astNodeKind`
(`compiler/tir/lower.orb:954`) puts the node's own class in the message, and the
census prints the tally (`unknown_census.py`, "What the front end gives up on, by
node class") and, since 2026-11-04, the file each class sits in. The tally said
what the pass gives up on; it did not say where, so a class of 93 could have been
one construct in one file or the same rule failing everywhere. Measured the same
day: `Match` is `compiler/ir/builder.orb` 58, `compiler/front/sema.orb` 48,
`compiler/emit/c_backend.orb` 41 and `compiler/tools/doctor.orb` 29. The `try` class is answered from two
places now. `declaredPayloadType` (`compiler/tir/lower.orb:553`) reads the payload the
signature writes -- `int`, `bool`, `string`, `float`, `object`. Where the signature writes
nothing, the annotation on the binding is the promise, and the build retypes the read to
it (`compiler/ir/builder.orb:3140`), so `val n: int = try digit(c) catch { return 9 }`
over a bare `-> result` lowers and the name loads back `int`. The 34 uses that asked for a
value type left the class; what remains of `try` is 6 handlers that fall through in
expression position. A named `catch` reads its message the way the build does:
`result_unwrap_err`, which `compiler/emit/c_backend.orb:870` types `string`, then the name
binds to that read, so the 6 that named their error left the class with the 34. Fourteen of the classes the table first printed turned out not to
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
chained place (`tok.line = 5` under a receiver it cannot type) was the residue:
216 on 2026-11-02 and 211 on 2026-11-03. Since 2026-11-03 the table answers more
of those hops: a field declared with another model's name is typed, and `o.i.n`
reads both hops. On 2026-11-04 the give-up table prints no `MemberAccess` row at
all, because a model call and a qualified variant construction now answer their
own type, and the write lowers under a receiver that has one.

`xs[i] = v` is the same write on an index, and it emits `store_index unit <container>
<index> <value>`. The container's own type is the condition, as it is for the field
write: 22 of these write positions were give-ups and 5 stayed that way under a
receiver this pass cannot read, measured 2026-11-04. The *read* `xs[i]` is the same
instruction the build emits for `xs.get(i)` -- `IROpcode.list_get` in
`compiler/ir/builder.orb` -- and it travels as `call <kind> get <container>
<index>`, with the element kind read from the receiver's type text.
`tests/frontend/list_index_read.orb` pins it. The 8 reads that stayed give-ups sat
over a `list` written without an element kind, and the message said so: `index read
needs the element type this pass does not keep`. Since 2026-11-05 a literal of
`[1, 2]` writes that element kind itself, and this run's give-up table prints no
index row.

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
19.3% to 18.3% (193 per mille to 183). 15 reads are still untyped, and the
census names the field each one asks for: `.v` 5, `.right` 4, `.left` 3.
Four left on 2026-11-05, when the type table began to carry the parameters the
model declares. `declaredFieldType` (`compiler/tir/lower.orb:259`) matches an
instance by the base of its type text -- `Box<int>` is the model `Box` with the
argument `int` -- and a field whose declared text is one of `TirType.params`
answers that argument. `list<T>` substitutes inside the container it names, so
`items` under `Bag<int>` is `list<int>` and `Bag<int>.items.get(0)` is
`call int`. Only a type this pass already states is taken: a builtin, `object`,
`list`, a `list` of one of those, or a model this file declares.
14 of the 15 stay, and every one of them is an instance that writes nothing:
`val b = Box { v: 3 }` keeps the bare name the source wrote, so the field's
declared text is still `T` and the argument lives in the value, not in the text.
The four `.all` and `.where` reads landed the same day, and the build is what
showed the answer: `Item.all()` and `Item.where(cond, arg)` put a model name in
receiver position, and the build emits no member read for them at all.
`compiler/ir/builder.orb:4711` and `:4721` set `modelBuiltin` to
`orbit_db_query_all` and `orbit_db_query_where`, called with the table name as a
string argument, and measured 2026-11-05 through `orbit build --emit-ir`, all four helpers --
`all`, `where`, `find` and `first` -- return a register typed `string`. This pass read `.all` as a field of a model that has no such field, which was the
E2004, and then reported E2005 for the call after it. It now carries the qualified
name on the call -- `call string Item.all`, with no `member` instruction -- the same
move that removed the phantom read for a method callee. Two controls landed with it: `tests/frontend/model_helper_name_is_a_field.orb` pins that a model declaring a field called `all` still reads it as `member int`, and `tests/frontend/undeclared_model_helper.orb` requires silence when the receiver names no model -- the build picks the helper by name and by the shape of the receiver, and the shape is missing there. Over the corpus that is 4
member reads, 4 call results and 8 loads of the model name: 16 instructions, and
`tests/suite/arena_sink_scope.orb` and `tests/suite/peephole_no_fold_side_effects.orb`
went from 8 untyped each to 0. `tests/frontend/model_query_helper.orb` pins the text
for `all` and for `where` with two arguments.
`tests/frontend/generic_instance_field_read.orb` pins the answered read --
`member int v0 v` under `param 0 0 b Box<int>` -- and the container read that
answers through it. `tests/frontend/generic_literal_field_read.orb` holds the
other side of the rule: a literal that names no argument keeps its E2004, so the
file prints nothing and the gate requires that silence. Its first function is the six-line case that used to exit 1
with `E2004 at 0:0: cannot type the member read .v` and suppress the file.
The count fell 44 to 23
on 2026-11-04, when a field read of an `object` stopped asking: the register the
build allocates for that read is declared `object` (`compiler/ir/builder.orb`),
which is the answer the same pass already gives the literal itself; which field
the run time then finds is not a type this pass can claim from the reader.
`tests/frontend/object_field_member_read.orb` pins the text. The element kind of a list left that list on 2026-11-04:
a receiver whose type text writes `list<int>` answers `int` for `get` and `at`
and `list<int>` for `slice`. `tests/frontend/list_element_read.orb` pins the
call, and `tests/frontend/list_field_read.orb` keeps the bare `list` a field
declares.
`tests/frontend/field_read.orb`, `tests/frontend/nested_field_read.orb` and
`tests/frontend/list_field_read.orb` pin the three answered field types;
`tests/frontend/crossfile_field.orb` pins that an imported name is not one of
them.

`[1, 2]` was the fourth: no rule for a list literal, so the elements were never
lowered and the name bound to one loaded back `unknown` -- the reader of types
and the lowerer disagreed about what the value was. 412 give-ups, 780 unknown
identifier reports, and the canonical text suppressed in every file that used
one. It emits `list` now and both readers answer `list`. Since 2026-11-05 a
literal whose elements answer one type emits that text -- `list<int>` for
`[1, 2]` -- and the kind is read off the elements the way the build IR reads it
(`listLiteralKindName`, `compiler/ir/builder.orb:1725`). A literal with no
elements keeps bare `list`, because there is no element to read a kind off.
`tests/frontend/list_literal.orb` pins both answers. Over the corpus the count
fell 393 to 321 and the metric from 4 to 3 per mille: 33 loads, 35 calls and 4
binary operands left it. The give-up table lost 18 with them -- 10 `for` loops
and the 8 index reads, each sitting over a literal that now names its own element
kind.

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
A loop over a value whose type text writes the element kind lowers as the
build's own list loop: `buildForList` (`compiler/ir/builder.orb`) emits the hidden
`<item>_idx` counter, one length read before the loop and the item through `get`, with an
increment block for a `continue` to reach. `tests/frontend/list_iteration_typed.orb` pins
that.
A loop over a `list` that names no element kind stays a give-up: binding the item to
`unknown` would suppress the same text while raising the count the ratchet holds.
`tests/frontend/list_iteration.orb` pins that refusal. On 2026-11-05 the give-up table
prints one of them, in `tests/suite/list_element_type.orb`; 10 left the class when a
literal began answering its own element kind. A label is no longer one of the reasons a
loop is refused.

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

The merge classes wanted one thing: a value that two branches both produce. A
`try` whose handler falls through asked for the same thing until 2026-11-04, and 20
of those cases read the statement position, where no value is read: that class now
prints no row. The build answers the merge *type* for an `if`:
`compiler/ir/builder.orb:3281` allocates its result register with `branchTypeName`
of the then branch. It answers nothing for a `match`:
`compiler/ir/builder.orb:3955` allocates that register typed `unknown`, and the arms
write into it. The `if` half landed on 2026-11-05 with that convention stated in
`docs/architecture/TYPED_IR.md`: both arms write one name with `bind unit join2 v2`
and `bind unit join2 v5`, and the block after the branches reads it with
`load int join2`. The type is the then branch's -- `branchTypeName`
(`compiler/ir/builder.orb:2134`) reads it that way -- taken only when the else
branch answers the same type, because one `instr` line carries one type and a join
of two different ones is not a statement the text can make. Over the corpus the `If`
row goes from 30 give-ups to 1 (the refusal above), 21 loads and 2 binary operands
leave the count, and five `tests/suite` programs come to zero untyped instructions:
`if_expression_value`, `if_expression_else_if`, `if_expression_no_phantom_branch`,
`ternary` and `result_stage2`. At that run `Match` rose 308 to 310, because a body
that is reached reports the match inside it.

The match rule then landed the same day, and it took 307 of those. A `match` is a
test chain in the blocks the statement `if` already builds: the discriminator is
read once with `tag int v0`, because `buildMatchExpr` compares one register against
every arm; each arm's test compares that register against the variant's declared
position -- a number that is not the frontend's to invent, because the emitter
numbers variants by declaration index, `tdName` + `_TAG_` + `vName` = `vi` at
`compiler/emit/c_backend.orb:2093`;
`== bool` and `branch` split the arm from the next test; an arm that returns writes
no jump and an arm that falls through jumps to the merge block; a wildcard writes no
test and takes the block the last test fell through to, so no empty block is printed
for it. A `match` whose arm binds a payload is refused by name -- 258 sites --
because reading the variant's data word is a second instruction this pass does not
print, and binding `r` to nothing would be the invention the count exists to expose.
`tests/frontend/variant_match_chain.orb` pins the chain, including the tag read
once, and `tests/frontend/variant_match_payload.orb` pins the refusal. Over the
corpus the denominator grew 5,829 instructions, `compiler/emit/ir_emit.orb` came to
0 untyped instructions and `compiler/front/sema.orb` fell 12 to 7.
`tests/frontend/if_value_join.orb` and `tests/frontend/if_value_branch_types.orb`
pin the two `if` halves.

What is left of the class list is an arm that binds a payload: 258 of the 270.
After them, `Match` 3 -- matches this pass still refuses for another reason -- a
fall-through `try` handler 6, an `if` in value position whose branches answer
different types 1, one `for` over a `list` that names no element kind, and a
`continue` outside any loop 1.
Lowering a loop lowers its body too, so the absolute count moves both ways and
the rate is what to read. On 2026-11-05 the census reads 275 unknown over 111,537
instructions, after a `match` became a test chain: the denominator grew 5,829
because whole bodies lower now, the count fell only 3, and the metric went 3 per
mille to 2 -- 275 in 111,537 is 2,47, and the 3 was recorded earlier the same day. Two
`tests/suite` programs gained untyped instructions (`union_bare_variant_pattern.orb`
0 to 2, `union_multi_payload.orb` 2 to 3) where a newly reached arm asks a question
the pass does not answer, and `compiler/front/sema.orb` fell 12 to 7. The run before
it read 278 unknown over 105,708
instructions, after the `if` in value position began to join its arms on one name:
21 loads, 2 binary operands and no member reads left the count, while 617 instructions
entered the corpus from bodies that lower now. The metric is per mille rounded to a
whole number -- 278 in 105,708 is 2,63 -- so the ratchet still holds at 3, and it is
now 13 instructions from 2. The run before it read 301 unknown over 105,091
instructions, after a model name in receiver position stopped being read as a field:
4 member reads, 4 call results and 8 loads left, and two `tests/suite` files came to
0. The metric is per mille rounded to a whole number -- 301 in 105,091 is 2,86 -- so
the ratchet held at 3 while the count fell 16; the next step below 2,5 takes it to 2.
The run before it read 317 over 105,069, after the model's declared parameters
entered the type table: 4 member reads answered and one give-up entered the tally,
because a body this pass could not reach before asks a question it still does not
answer. The census is reproducible on this tree: two runs
printed the same 214 files, 105,069 instructions, 317 `unknown`, 0 silent and 665
diagnostics. One number on this page claimed otherwise on 2026-11-05, and the
mechanism is worth keeping: the driver prints `instructions with a real type`
(104,752) one line below `instructions typed unknown` (317), and 104,752 + 317 is
the total 105,069. The sum is the check that was not taken. The baseline and this
page carry the run that was also handed to the gate as a document
(`measure.py ratchet --from-json`), so the two agree by construction. The run
before it read 321 over
104,610 instructions, after a list literal began answering its own element kind:
33 loads, 35 calls and 4 binary operands left the count, and 18 give-ups with
them. The metric the ratchet holds moved 4 to 3 on this one. The run before it read 393 over
104,185, after a labelled `break` found its target: the row that printed 4
prints nothing, and 3 of those loops moved to the element-kind question. A named `catch`
reads its message now, so the row that printed 6 prints nothing. The run before it read 399 over 103,986, after a `try` binding annotation
began answering the read the way the build answers it: 26 loads stopped being `unknown`
and 22 give-ups left. The metric holds at 4 per mille. Earlier the same day it read 425 over 103,614 -- one higher than the
424 before it, while 12 `for` give-ups left and 321 instructions entered the corpus:
lowering a loop body adds the instructions it holds, and one `+` inside a newly readable
body has an operand no table answers. It read 424 after
`object` joined the payloads a written `result` can name -- 25 loads stopped being
`unknown` and 6 `try` give-ups left -- and 449 over 103,281, with 38 `try` give-ups gone, and 454 after the index
form of a list read
started lowering: the 8 cases in the corpus sit under a `list` whose type text
names no element kind, so they changed message, not count. Earlier the same day it
read 454 with a field read of an `object` answering `object`. Earlier
the same day it read 485, after `pop` joined `get` and `at` on the element kind, and
511, after a `+` with a string operand answered `string` the way
`compiler/ir/builder.orb` already answers it, and 568, after `std/convert/codec.orb`
wrote its payloads. Earlier the
same day it read 576 over 102,668. Earlier the same day it read 614, before `system` was read
as the receiver the checker names, 739 before `ok` and `err` were read by name,
and 1,134 before a list write answered `void`. The count falls faster than the
rate: this pass is in the corpus it measures, and every rule added grows the
denominator with it. The per-mille the ratchet holds moved 5 to 4 when a labelled
`break` found its target. Earlier the same day it read 1,757 over 102,785, before a
qualified construction of a declared type stopped being read as a value off
nothing, and 2,156 over 103,008 before a field declared `list<T>` carried that
text to the read. Earlier the same day it read 4,050 over 102,971, before a
field declared `list<T>` carried that text to the read. Earlier the same day it read 4,830 over 102,931, before a
list element read started answering the kind its receiver's type text writes.
The same tree read 6,356 over 105,469 before a method
callee stopped entering a member read of its own, and 17,410 over 105,754 before
the frontend read imports at all. The older records stand: 17,388 over 105,644 on
2026-11-03, 20,005 over 103,333 on
2026-11-02 and 25,489 over 86,942 at
the start of that day.
The ratchet reads the rate. Measured again on 2026-11-04, after the rules of the
same day, the most untyped instructions in one file are `compiler/tools/doctor.orb`,
73 of 11,706 -- 0.6%. Among the files the table puts first, the largest share is
`tests/suite/object_literals.orb`: 18 of its 164 instructions, 11.0%. The
`tests/std/test_json.orb` row between them, 25 of 581 at 4.3%, is the one the
unwritten `result` payload explains. The sentence this replaces named `compiler/front/parser.orb`
as the worst by share; that file is no longer in the ten first, so the claim was a
record of an older tree. Re-run the census rather than trusting these numbers.

Two tools, and the difference matters. `unknown_census.py` is the
**measurement** and never fails anything. `scripts/measure.py ratchet`
is the **gate**: it reads the census output, compares two of the
numbers against a committed baseline in `scripts/baselines/`, and
fails if either went *up*. It does not fail because the count is high -
0.3% is the number the type work has to be scoped against, and a
zero-bar gate is a gate everybody deletes. Run on 2026-11-02, after the
baseline moved down to the measured numbers:

```console
$ python scripts/measure.py ratchet --compiler <orbit> --cc gcc
  unknown_per_mille               168  baseline    168  unchanged
  silent_per_mille                  0  baseline      0  unchanged
Finished unknown-count: 168 (baseline 168, ratchet holds)
```
Run again on 2026-11-04, after fourteen baseline moves the same day:

```console
$ python scripts/measure.py ratchet --compiler <orbit> --cc gcc
  unknown_per_mille                 4  baseline      4  unchanged
  silent_per_mille                  0  baseline      0  unchanged
Finished unknown-count: 4 (baseline 4, ratchet holds)
```

The run on 2026-11-05, after the list literal answered its own element kind:

```console
$ python scripts/measure.py ratchet --compiler <orbit> --cc gcc
  unknown_per_mille                 3  baseline      4  -1
  silent_per_mille                  0  baseline      0  unchanged
Finished unknown-count: 3 (baseline 4, ratchet holds)
```

What the second number holds now is the one-to-one tie above. An opcode that
starts producing `unknown` without a diagnostic, or one of the five that stops
firing once per instruction, moves it off zero and the gate fails.

Raising a baseline is a deliberate act: `--write-baseline` refuses to
move a number up unless `--allow-regression` is also passed. It rewrites the rest of
the file on every run -- the file count, the instruction count and the per-file
`by_file` table -- so a commit can refresh those context numbers without moving
either metric: `bef0782` changed 5 lines and added 4, and both metrics stayed 6 and
0. The run on 2026-11-05 rewrote 17 lines and added 17: the metric line, the two
context lines and 14 per-file rows, five of them down to 0. A per-file entry going
to 0 is the useful half of that churn: `tests/std/`
`test_codec.orb` reached 0 untyped instructions when the decodes wrote their
payload. So the
count can only go down, which turns "do not regress this" from a rule
people follow into a property the build enforces.

## The frontend gate is 65/65

`scripts/corpus_gates.py frontend` runs 65 fixtures and all 65 pass (two of
them, `syntax_error.orb` and `unresolved_type.orb`, could not build for most
of this cycle, and both missing imports are fixed). `print_pipeline.orb` pins
`call void print`, which is what made `orbit frontend examples/hello.orb`
fail before. Ten pin an absence of output rather than a text, and the gate
owns that list in `EMPTY_EXPECTATIONS`: for a suppressed file a golden would be
the wrong artifact. 55 `.tir` goldens sit in `tests/frontend/expected/`.
`interp_parts.orb` pins the interpolated string, and its
hole is written `$` because a fixture cannot embed `${`: the lexer that reads
the fixture's own literal would interpolate it, so the marker is decoded in the
gate's test plumbing rather than as a language escape.
`variant_match_payload.orb` moved from the absence list to a golden when the payload arm started lowering on 2026-11-06, and `variant_match_bindless.orb` took its place as the refusal control.
`match_value_join.orb` pins the join a `match` in value position writes on every
arm, and `match_value_branch_types.orb` is its refusal control.
`list_refinement_branch.orb` pins a push inside an `if` typing the read after
it, and `list_refinement_callee.orb` is the boundary: a push the callee performs
does not type the caller's local. `generic_union_payload.orb` pins `data int`
for an arm on `Box<int>`, where the declaration writes `T`.
`if_value_block_local.orb` pins an `if` whose branch declares the local it
answers.
`crossfile_field.orb` is the boundary case: a field whose type is
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
