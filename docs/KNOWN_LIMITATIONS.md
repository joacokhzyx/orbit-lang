# Known Limitations (0.1.0)

This is the honest list. I keep it next to the docs that use these
features so you don't discover them at midnight. Each entry says
what happens today, how to work around it, and what would change it.
Nothing here is a roadmap promise with a date — it's what I measured
on this build.

Tested on: `orbit 0.1.0` fixed-point build (Windows x86-64, gcc),
September 2026. Linux paths are marked UNTESTED below where I
couldn't run them.

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
RAPL). On Windows the honest proxy is CPU time plus memory —
never converted to joules with a universal factor. The benchmark
guide (`docs/guides/benchmark-methodology.md`) enforces this.

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

## Native backend is experimental

`--backend=native` (x86-64 machine code) is research in progress.
The C backend is the supported path until native matches it on
behavior and bootstrap checks.

## DB migrations are open

There is no migration story: no schema versioning, no upgrade
path, no transaction-boundary contract for app code. The
migrations guide (`docs/guides/migrations.md`) describes the
manual practice that works today.

## Two servers, one port: no error on Windows

Starting two servers on the same port on Windows doesn't fail
loudly in my test — both processes kept running and the port
answered. Don't rely on a bind error to catch the mistake; check
with `netstat -ano | findstr <port>` and stop the older process.
UNTESTED on Linux.
