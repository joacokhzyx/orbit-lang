# orbit doctor

`orbit doctor` looks over your `.orb` files and reports what it finds. It
does not change your code unless you ask it to with `--fix`.

```sh
orbit doctor                  # scan the current directory
orbit doctor examples         # scan one directory tree
orbit doctor --fix            # scan, then apply the fixes it knows
orbit doctor --fix --dry-run  # say what it would change, change nothing
orbit doctor --quiet examples # findings only, no summaries
orbit doctor --verbose .      # also the per-phase timings
orbit doctor --only D006,D007 # just these checks
orbit doctor --skip D003      # everything but this one
orbit doctor --min-severity error   # hide warnings
orbit doctor --baseline known.txt   # print what is listed, do not fail on it
orbit doctor --format json examples  # findings as JSON on stdout
orbit doctor --color always examples # force ANSI colors
orbit doctor --help           # usage
```

With `--format json`, stdout is a JSON array of objects and nothing else
(exit codes unchanged), so editors and CI can parse it. The original six
keys are a contract and are always present:

`{file, line, code, severity, message, fix}`

Four more keys are additive, and mean a finding can be acted on without a
human reading it:

| Key | What it is |
|---|---|
| `column` | 1-based column, or `0` when the finding is about a whole line or the whole file. |
| `layer` | Which analysis produced it: `text`, `ast`, `ir` or `sema`. |
| `fix_kind` | `safe`, `unsafe` or `""` when there is no fix. |
| `applied` | `applied`, or a sentence saying why not, after a `--fix` run. |
| `edits` | The fix as line ranges: `{start_line, end_line, kind, text}`. `end_line` exclusive when it is `start_line - 1`, that is, an insertion in front of that line. A consumer can apply them itself. |

Reading `edits` is a supported interface, not a dump: a check that can fix
itself always emits them, and `applied` says whether doctor managed to.

## Presentation

Every finding carries a severity: `error` for `D001` (no toolchain)
and `D008` (the file itself does not compile), `warning` for the
rest. The text line reads `file:line severity [CODE] message fix:
action`, with the location bolded, the severity red/yellow and the
code cyan when colors are on. Paths print relative to the scanned
directory when possible. Colors follow `--color always|never|auto`
(`auto` honors `NO_COLOR` and `TERM`, and stays plain on consoles
that do not advertise themselves); `--format json` never colors.

Exit codes: `0` means clean, `1` means there are findings, `2` means the arguments were not understood.

## Checks

Every finding prints `file:line`, a code, and a one-line fix, for example:

```text
app.orb:12 [D002] route GET /users/:id collides with app.orb:8 (GET /users/{id}); both normalize to /users/:param. fix: merge the handlers or give the paths distinct shapes.
```

| Code | What it reports |
|---|---|
| `D001` | No C compiler answered. Doctor tries `ORBIT_CC`, then `CC`, then `gcc`, `clang`, `cc` in that order - a wider net than the build, which resolves `ORBIT_CC`, `CC`, `cc` and stops. |
| `D002` | Route conflicts: exact duplicates, paths that match once `:params` and `{params}` are treated alike (so `/users/:id` and `/users/{uuid}` collide), and specific routes covered by a same-method wildcard. |
| `D003` | A `private fn` that nothing in the scanned files calls. Public functions are never reported here, since files outside the scan may import them. `main` and `extern` functions are never reported. |
| `D004` | A `model` that nothing in the scanned files references, including use as a type or through calls such as `Product.all()`. |
| `D005` | An unknown member on `system`, for example `system.cores()`. The valid members are `uptime`, `pid`, `active_workers`, `http_requests_total`, `latency_avg_us`, `latency_p50_us`, `latency_p95_us`, `latency_p99_us`. |
| `D006` | Trailing whitespace on a line. |
| `D007` | A file that does not end with a newline. |
| `D009` | A string literal that looks like a hardcoded credential (`sk-`, `ghp_`, `AKIA`, `-----BEGIN`, `password=`, `secret=`, `token=`, `apikey=`). **The value is never printed**, only the matched prefix: a diagnostic that quoted the string would copy the credential into CI logs and every terminal that ran the tool. A literal must have real content after the prefix, so the check does not flag its own prefix table. |
| `D010` | A SQL statement (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `DROP`) built by string interpolation. A keyword alone is not a finding, and only the closing line is inspected, so this under-reports rather than guessing. |
| `D011` | A `POST`/`PUT`/`PATCH`/`DELETE` route that returns without a role guard or a request validation block. Reads the runtime's own guard vocabulary (`orbit_auth_*`, `req.body`, an early-returning `if`), so a route guarded through a helper is not reported -- it under-reports rather than guess. |
| `D012` | An import whose module is named nowhere, directly or through what that module itself imports. The transitive part is load-bearing: without it, removing the flagged imports from `std/io/io.orb` broke both files at the very next build. |
| `D014` | A database query inside a loop: one round trip per iteration where one per request was meant. |
| `D015` | A **string** built by `+` inside a loop over a collection, so the whole prefix is copied every iteration. It requires the accumulator to be known to be a string -- `sum = sum + items.get(i)` over ints is the same shape and costs nothing, and reporting it put 32 findings into `std/` and `tests/suite/`. Advisory: the scope gate prints it and does not fail on it, because a test whose purpose is to assert `joined` produces `"red,blue,"` cannot also be told to stop concatenating. |
| `D016` | A bare number of three or more digits that appears twice in a file under a name that says nothing about what it is. Keyed on the NUMBER, not on number-and-name: the same timeout written under two vague names is one constant hiding in two places. |
| `D017` | Cyclomatic complexity: base 1 plus one per `if`, `while`, `for`, match arm and `try`. 11-20 is a warning, over 20 is an error. Advisory in the scope gate, because a test whose `main` asserts fifteen behaviours IS complexity 20 and the advice would be about the test. |
| `D019` | An allocation inside a loop, so it is repeated on every iteration. Matches the runtime's allocating constructors by name. An empty list literal is exempt: `var acc = []` inside a loop is how an accumulator is written, and hoisting it would be wrong. |
| `D022` | Two match arms binding the same variant, so the later one is dead. The first matching arm wins, so the duplicate never runs. Compared on the fully qualified pattern, so `Foo.Bar` and `Baz.Bar` cannot collide. `_` is not a variant and is skipped. |
| `D027` | A call that returns a `result`, called as a statement. The error is discarded and the program continues as if the call had succeeded. Only statement position counts: bound to a `val`, returned, or handled by `try ... catch` are all silent. Needs the callee's declared return type, which is why `DoctorDecl` carries one. Scoped to `result` on purpose -- a discarded `int` is sometimes deliberate. |
| `D028` | A `var` whose last write nothing reads afterwards, so the value it holds is never used. One finding per name per function. `val` is silent: a `val` has one write and is not a mutable store. A write inside a loop body is silent, and that is a real limit rather than a hedge: `var p = 1; while k < 16 { use(p); p = p * 2 }` reads `p` on the next iteration, and a single linear pass cannot see it. Proving otherwise needs a fixpoint over the loop, which is not this check. Walking the loop body before its condition matters for the same reason -- the condition has the last word, because that is when it runs. The receiver of a method call counts as read: `pick(xs, bare).len()` parses as `Call(callee: MemberAccess(object: Call(...)))`, so reading only the argument list loses the receiver's own arguments. `var mut` is reported: stating the intent to reassign does not make the value read. Reaches `fn` and `route` bodies; `extern fn` is skipped. |
| `D025` | A value read from the request reaching a database call. Sources are `orbit_http_body_get`, `orbit_auth_bearer_token` and `orbit_auth_current_role`; sinks are the six `orbit_db_*` query entry points. Taint is direct and per function or route body: a name is tainted when bound to something containing a source or a tainted name, and stops when rebound to something containing neither. Reported on the sink call, which carries a position. |
| `D023` | A name shadowed in an inner scope and read again after that scope closes. The read returns the INNER value, because the emitted C declares one variable per name. Shadowing alone is not reported: the repository contains nineteen and all are correct. One finding per name per function, because sibling blocks that each redeclare it produce the same location and the same sentence. Reaches `fn` and `route` bodies, statements and expressions including value-position `if`/`match`/`try` and model literals. It does not reach D017-D021's route gap: those take a `FunctionDeclNode`, so routes are still unexamined by them. |
| `D021` | A function parameter its own body never reads. `extern fn` is skipped, since those bodies are empty by construction and the parameter is documentation. Reported on the `fn` line: the parser keeps parameter names but not their positions. |
| `D018` | A function that calls itself where the call is not the value it returns. `return self(n)` is tail; `return 1 + self(n)` is not, and holds a frame per level. Advisory for the same reason as D017: `tests/suite/fn_recursive.orb` exists to test recursion. |
| `D013` | A `var` that is never assigned again. A `var` exists because something changes it; this one is a `val` wearing a `var`. `var mut x` is never reported, because `mut` is an explicit statement of intent. Assignments must actually look like `name =` or `name +=`; `==`, `<` and `!=` are comparisons, and a bare *use* of the name is a read, not a write. |
| `D008` | A file the compiler could not accept: it does not parse, or it does not pass the semantic checks. Both halves are reported separately, because they have different causes and different fixes. |

Unused reports (`D003`/`D004`) are deliberately conservative. A name counts as used when the compiler's AST walk finds it or when a whole-word use appears anywhere outside its own declaration line, so generated or loosely referenced code is left alone. If doctor stays quiet about a helper you suspect is dead, it is erring on the side of not bothering you.

A few notes on scope:

- Doctor scans `.orb` files under the given directory, recursing into subdirectories. Files and directories whose names start with a dot are skipped.
- A scanned tree is treated as one project: routes and declarations in
  different files are checked against each other. A directory of
  independent services (like `examples/`) therefore reports cross-service
  findings (e.g. two services both defining `GET /health`). Scan a single
  service directory or file when that is what you mean.
- If the path you pass ends in `.orb`, doctor treats it as a single file.
- When a file does not parse, doctor still runs the text-based checks (routes, `system.*`, whitespace) on it and skips only the AST-based unused analysis for that file.

## --fix

`--fix` applies the fixes doctor knows how to make, which today are the two
whitespace tidies:

1. trailing-whitespace removal per line,
2. a missing final newline at end of file.

It never renames, moves, deletes, or restructures code, and it never touches
route, model, function, or `system.*` findings. The exit code then reflects
the state after fixing, so a clean `--fix` run exits `0`.

Every fix goes through one engine, and that engine holds three promises:

- **Nothing outside the edited range changes.** Fixes splice into the original
  text by offset. A file that is fixed on line 900 is byte-for-byte identical
  everywhere else, including its line endings: a CRLF file stays CRLF, and no
  comment is reflowed.
- **Two fixes to one line is a conflict, not a guess.** If two findings both
  rewrite the same line, doctor applies neither and says so, rather than
  merging them into something neither check asked for.
- **A fixed file is verified before it is written.** The front end is always
  re-run on the result. With `--fix` the C step runs too, unless you pass
  `--fast`. The result is only written if both pass.

`--unsafe` extends `--fix` to fixes marked `unsafe` (structural ones). No
check emits those yet; the flag exists so that the day one does, the safe path
is the default rather than the other way round. `--dry-run` reports the fix
and its verification without writing anything.

## Adopting new checks

A new check arrives as an error, which breaks every tree that has the problem.
That is what the baseline is for:

```sh
orbit doctor --baseline known.txt .   # report, but do not fail on what is listed
```

Each line of the baseline file is `CODE file:line`, and a finding that matches
one is printed and marked `(in baseline: known finding, not counted toward
the exit code)` instead of failing the run. Delete a line once you have fixed
it, so the baseline only ever shrinks.

`scripts/doctor_gate.py` pins the exact output of each check against the
goldens in `tests/doctor/golden/`, so a check cannot quietly change what it
says.

## What doctor remembers

The semantic half of `D008` runs the real typechecker, and that is the slowest
thing doctor does. Its answer is cached on a **hash of the file's contents**:

- a file you have not touched, and none of the modules it imports, is not
  typechecked twice
- a file you edited, even by one byte, is typechecked again
- **a module you edited is followed through to every file that imports it**,
  directly or not

That last one is the whole reason the key is a fingerprint and not a hash: the
semantic check resolves and typechecks the import closure, so the answer belongs
to the file *and* everything it pulls in. A per-file cache key reported files
clean that `orbit check` rejected, which is the worst thing a linter can do.

```sh
ORBIT_DOCTOR_CACHE=0 orbit doctor .          # do not use or write the cache
ORBIT_DOCTOR_CACHE=/tmp/mycache orbit doctor .
```

The first run on a fresh clone pays for every file; later runs on the same tree
do not. One consequence is worth knowing: a cached answer does not reprint the
compiler's diagnostic, so that finding points you at `orbit check <file>` for
the detail instead of showing it above the line.

## Order of findings

Findings are printed by the phase that produced them, not grouped by file: the
text checks first, then the semantic check (`D008`). That is a consequence of
the parse pass being shared — the fingerprint of one file depends on the imports
of another, so the semantic pass has to come after the whole tree is parsed.
Every finding is still reported, and the order is pinned by the goldens.

A file that does not parse is reported by the parse pass and is not typechecked
at all, which is why a syntax error no longer also produces a semantic error:
there is nothing to typecheck yet.

## Which directories are gated

`orbit doctor .` over this repository reports 196 findings, and almost none of
them is something to fix:

| | n | what it is |
|---|---|---|
| D008 | 57 | files in `tests/negative`, `tests/doctor`, `tests/parity` that must NOT compile |
| D002 | 105 | route collisions inside those corpora, plus 17 across `examples/` |
| D006/D007 | 28 | whitespace, which were real and are fixed |

So the gate names what must be clean instead of baselining the rest.
`scripts/doctor_scope_gate.py` runs doctor over `compiler`, `std` and
`tests/suite`, and those three are expected to produce nothing. Four dead
models came out of making that true: `IRTraitMethod` and `Loc` in the
compiler, `JwtHeader` and `JwtToken` in std.

`examples/` is deliberately not in the list. It is a directory of
**independent services**, and a tree scan reads five services' `GET /health`
as one program's conflicting routes. That is the correct analysis of the wrong
input: scan a single service, or a single file, when that is the question.

## Reading production telemetry

A running service records a per-route ledger: request counts, p50/p95/p99, a
latency histogram and an energy estimate. Until now it was reachable only at
`/_ledger/data`, on loopback, over HTTP -- which means a static tool could not
read it. It would have to start a server, drive traffic through it and know when
to stop, and the interesting cases only exist *after* the service has been up: "this
route has never been requested" is not knowable from a fresh process.

Set one environment variable and the service writes the same JSON to a file at
exit:

```sh
ORBIT_LEDGER_OUT=/tmp/ledger.json ./my_service
```

The file is written atomically (temporary plus rename), so a reader sees the old
snapshot or the new one and never half of one. With the variable unset nothing
happens and there is no cost. `runtime/test_ledger_percentiles.c` covers the
hook, the rename, and the opt-in default.

### Checks that carry a production number

| Code | What it reports |
|---|---|
| `D031` | A route the source registers that the ledger has **no record of**. Dead code that reading the source cannot find: `D003` says "nothing in the scanned files calls this", which is a different and weaker claim than "no request has ever reached it". |
| `D032` | A route whose **arena overflowed** -- `arena_overflow` non-zero in the snapshot. A leak counted in production, not inferred from reading allocations. |
| `D033` | A route whose **measured p99 exceeds the budget** in `ENGINEERING.md`. The budget is a claim about production and this is production disagreeing with it. |

These read a snapshot; they are silent without one, which is not "assume the
best" but "a check that reports production problems with no production data is
guessing, and a guess here cannot be acted on or refuted".

```sh
orbit doctor . --telemetry /tmp/ledger.json     # or just set ORBIT_LEDGER_OUT
orbit doctor . --skip D031                       # not for you
```

The budget is read out of `ENGINEERING.md` rather than hard-coded, so the check
and the document cannot drift apart. Change the document and the check follows.
`--budget-doc` points at a different copy, which is how the goldens run from a
throwaway directory. No budget found means `D033` stays off, rather than
inventing a threshold.

## Gates

Doctor prints the contributor gate commands at the end of every run for reference. It never runs them itself.

```sh
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

Run those from the repository root when you change the compiler. See `docs/COMMANDS.md` for the full command reference.
