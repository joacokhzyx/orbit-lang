# Known Limitations (0.1.0)

This is the honest list. I keep it next to the docs that use these
features so you don't discover them at midnight. Each entry says
what happens today, how to work around it, and what would change it.
Nothing here is a roadmap promise with a date — it's what I measured
on this build.

Tested on: `orbit 0.1.0` fixed-point build (Windows x86-64, gcc),
September 2026. Linux paths are marked UNTESTED below where I
couldn't run them.

## Writes: Model.create returns false

`Note.create()`, `Product.create()`, and `Post.create()` return
`false` at runtime, with both literal JSON and `req.body()` input.
The handler still responds — you'll see the `400` branch your code
already has — but no row is stored. Reads are unaffected.

Workaround: build read and validation flows now; treat writes as
unavailable until this entry changes. The blog tutorial
(`docs/tutorials/blog-api.md`) shows the pattern.

## Auth helpers: bearer_token returns an empty reply

Any route that calls `req.bearer_token()` answers with an empty
reply (curl reports `000`, no status, no body). This hits
`examples/sqlite_notes.orb` (`GET /v1/notes/secured`). The same file
links only when the program also uses a database operation — without
one, the build fails with `implicit declaration of
orbit_auth_bearer_token`. `req.has_role()` belongs to the same
family and is unverified at runtime.

Workaround: check a shared key from `req.query()` instead, as the
tutorials do. Don't ship bearer-token auth on 0.1.0.

## Path parameters match, values are raw

Routes with `:id` or `{id}` segments match at runtime and bind
through `req.param("id")` (verified with GET and DELETE, including
static-over-param precedence and trailing slashes). Two limits
remain: captured values are not percent-decoded, and at most 8
captures bind per request. Query values (`?id=`) keep working
alongside.

## Custom tables aren't created

On startup the runtime creates exactly four tables — `notes`,
`products`, `users`, `sessions` — and seeds demo rows when
`products` is empty. A model with any other name (for example
`Post`) gets no table: `.all()` returns `[]` and `.create()`
fails. Tutorials build on `Note` and `Product` for this reason.

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
