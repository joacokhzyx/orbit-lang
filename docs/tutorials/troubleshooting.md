# Tutorial: Troubleshooting

Problems in the order you'll most likely meet them. Each entry
gives the symptom, the cause I found, and the fix that worked on
`orbit 0.1.0` (Windows, September 2026). Linux notes are marked
UNTESTED where I couldn't run them.

## The port is taken - or is it?

**Symptom:** you start a second server on a busy port and… both
keep running. On Windows I measured no loud bind error: two
processes on one port, the port still answering.

**Fix:** don't trust the startup banner alone. Check who's
listening, then stop the older process or pick a new port (the
port is just the first argument):

```powershell
netstat -ano | findstr 8080
taskkill /F /PID <pid>
.\health_service.exe 8081
```

Linux (UNTESTED): `ss -ltnp | grep 8080`, then `kill <pid>`.

## The DB service exits with no message (Windows)

**Symptom:** `catalog_service.exe`, `sqlite_notes.exe`, or
`blog_api.exe` starts and vanishes instantly - no banner, no
log, no error.

**Cause:** `sqlite3.dll` isn't next to the exe. Windows loads
it from the application directory; the build links against
`runtime/vendor/win-x64/sqlite3.lib` but the DLL must travel
with the binary.

**Fix:**

```powershell
Copy-Item runtime\vendor\win-x64\sqlite3.dll .
.\blog_api.exe 8080
```

Services without database use (`health_service`,
`file_server`) don't need it.

## Slow first start, fast restarts

**Symptom:** first boot prints `Ready in 1744.3 ms`; later
boots print `Ready in 8.1 ms`. Is something wrong?

**Cause:** no. First start opens `orbit.db` in the working
directory, creates the `notes`/`products`/`users`/`sessions`
tables, and seeds demo rows when `products` is empty. That
one-time work costs about 1.7 s on my machine. Later starts
find the file ready.

**Fix:** none needed. Don't benchmark cold starts against warm
ones - and don't ship a benchmark without saying which you
measured (see the benchmark guide).

## `orbit build` fails on `orbit_auth_bearer_token`

**Symptom:**

```text
error: implicit declaration of function 'orbit_auth_bearer_token'
```

**Cause:** auth declarations are compiled in only when the
program uses a database operation (`-DORBIT_WITH_DB` path). A
file that calls `req.bearer_token()` with no `Model.all()` /
`where` / `create` anywhere won't link.

**Fix:** this is a compiler gap, not your bug - and bearer
routes return empty replies at runtime anyway in 0.1.0. Use a
`?key=` check per the tutorials until the limitation entry
changes.

## `orbit build` fails on `orbit_http_header_get`

**Symptom:** `implicit declaration of function
'orbit_http_header_get'` when calling `req.header(…)`.

**Cause:** same family - the header helper isn't declared in
generated programs in this build.

**Fix:** read what you need through `req.query()` or
`req.body()` instead.

## `:param` routes always 404

**Symptom:** `GET /echo/abc123` against
`route GET "/echo/:id"` answers the router's `404 Not Found`;
your handler never runs. Same for `{id}` and for DELETE.

**Cause:** path-parameter matching isn't wired at runtime in
0.1.0, for either syntax.

**Fix:** pass identifiers as query values
(`GET /notes?id=…`) until the limitation entry changes.

## `Model.create()` answers 400

**Symptom:** your POST handler's `create()` branch never
succeeds - literal JSON and `req.body()` alike return `false`.

**Cause:** writes are broken at runtime in this build (cause
still under investigation; reads are fine).

**Fix:** keep the failure branch - it's real behavior - and
design around reads plus validated echoes, as the tutorials do.
Don't retry in a loop; it won't help.

## The canonical C source is stale

**Symptom:** `build_selfhost.py --check-stale` fails - the
converged output doesn't match the committed canonical source.

**Cause:** someone changed `compiler/*.orb` without promoting,
or generated output drifted.

**Fix:** only after an intentional compiler change, and after
reviewing the diff:

```sh
python scripts/build_selfhost.py --promote
```

Then run the full gate (bootstrap → parity → suite) before
committing. Procedure per [Getting Started](../GETTING_STARTED.md);
the promote step itself is UNTESTED in this track - I changed no
compiler code.

## curl prints `000` then the real code on POST

**Symptom:** a POST shows a `000` line before the actual
`201`/`400`/`401` in some Windows runs.

**Cause:** connection-close timing between curl and the server
on requests with a body. The second line - with the body - is
the authoritative one; the server log shows one request.

**Fix:** compare against the server log line, not the first
curl line. GETs don't show this.
