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

## Gates

Doctor prints the contributor gate commands at the end of every run for reference. It never runs them itself.

```sh
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

Run those from the repository root when you change the compiler. See `docs/COMMANDS.md` for the full command reference.
