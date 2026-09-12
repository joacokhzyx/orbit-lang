# Orbit 0.1.0 — Release Notes (draft)

Orbit 0.1.0 is available. It's the first versioned development
release: a self-hosted compiler, an HTTP runtime with SQLite,
and docs you can run. It still can't do writes, bearer auth, or
path parameters — the list is below, with workarounds.

## What it does

- Compiles Orbit to C99 and then to a single native binary
  (Windows + Linux; macOS builds locally).
- Serves HTTP with per-request arenas, Kynx admission control,
  and a live per-route cost ledger (`/_ledger`).
- Reads from SQLite through models (`all`, parameterized
  `where`); seeds demo data on first start.
- Ships `run`, `check`, `fmt`, `doctor`, and single-host
  `cluster` commands, each with a real contract.
- Measures itself: `system.*` counters, `/metrics`, ledger —
  no invented numbers.

## What it fixes (since the rc cycle)

- Startup errors say what happened instead of failing silent
  (except the missing-DLL case — still silent, still tracked).
- Server logs flush live to files, so `cluster logs` follows
  reality.
- `try`/`catch` around `result` values; struct bindings from
  `list.get()` are annotated.

## What it still can't do

Single-host cluster only; no joules on Windows; no p50/p99;
Windows drain is kill; native backend experimental; DB
migrations open. Plus, found while writing these notes:
`Model.create()` returns `false`, `req.bearer_token()` answers
empty, `:id` routes never match, `req.file()` saves nothing,
custom tables aren't created. Each has a workaround in
[Known Limitations](KNOWN_LIMITATIONS.md).

## Verify it yourself

```sh
python scripts/build_selfhost.py --cc <gcc-or-clang> --check-stale
python scripts/verify_seed.py --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/parity_selfhost.py --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <path-to-orbit>
```

Then build a service from [Getting Started](GETTING_STARTED.md).
If it breaks, file an issue with the `.orb` file and what you
expected — I read everything.
