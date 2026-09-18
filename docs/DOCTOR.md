# orbit doctor

`orbit doctor` looks over your `.orb` files and reports what it finds. It does not change your code, with one narrow exception described below.

```sh
orbit doctor                  # scan the current directory
orbit doctor examples         # scan one directory tree
orbit doctor --fix            # scan, then tidy whitespace only
orbit doctor --fix examples   # tidy whitespace under one tree
orbit doctor --help           # usage
```

Exit codes: `0` means clean, `1` means there are findings, `2` means the arguments were not understood.

## Checks

Every finding prints `file:line`, a code, and a one-line fix, for example:

```text
app.orb:12 [D002] route GET /users/:id collides with app.orb:8 (GET /users/{id}); both normalize to /users/:param. fix: merge the handlers or give the paths distinct shapes.
```

| Code | What it reports |
|---|---|
| `D001` | No C compiler answered. Doctor tries `ORBIT_CC`, then `CC`, then `gcc`, `clang`, `cc` in that order, the same order the build uses. |
| `D002` | Route conflicts: exact duplicates, paths that match once `:params` and `{params}` are treated alike (so `/users/:id` and `/users/{uuid}` collide), and specific routes covered by a same-method wildcard. |
| `D003` | A `private fn` that nothing in the scanned files calls. Public functions are never reported here, since files outside the scan may import them. `main` and `extern` functions are never reported. |
| `D004` | A `model` that nothing in the scanned files references, including use as a type or through calls such as `Product.all()`. |
| `D005` | An unknown member on `system`, for example `system.cores()`. The valid members are `uptime`, `pid`, `active_workers`, `http_requests_total`, `latency_avg_us`. |
| `D006` | Trailing whitespace on a line. |
| `D007` | A file that does not end with a newline. |
| `D008` | A file that did not pass the compiler's own parse and typecheck. You'll see the compiler's error just above the finding. |

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

`--fix` applies two whitespace tidies and nothing else:

1. trailing-whitespace removal per line,
2. a missing final newline at end of file.

It never renames, moves, deletes, or restructures code, and it never touches route, model, function, or `system.*` findings. Line endings are preserved per line, so a CRLF file stays a CRLF file. Fixed files are listed as `fixed <path>: ...` on output, and the exit code then reflects the state after fixing.

## Gates

Doctor prints the contributor gate commands at the end of every run for reference. It never runs them itself.

```sh
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

Run those from the repository root when you change the compiler. See `docs/COMMANDS.md` for the full command reference.
