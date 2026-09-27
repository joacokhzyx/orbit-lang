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

**Fix:** none needed. Don't compare a cold start against a warm
one, and don't publish a number without saying which of the two you
measured (see [Performance notes](../PERF.md)).

## `Model.create()` answers 400

**Symptom:** your POST handler's `create()` branch never
succeeds on the *second* attempt at the same `id`.

**Cause:** the model's `id` is the table's primary key, so the
second insert of the same id is a constraint violation and
`create()` answers `false`. Nothing is wrong with the payload or
the runtime - re-posting an id you already stored cannot work.

**Fix:** decide what a repeat means for your service - a conflict
(409) or an update - and make the id unique per post. Keep the
failure branch: it is the branch a duplicate lands in, and
`create()` also answers `false` when the payload has no usable
fields.

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
