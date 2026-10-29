# Orbit Examples

A ladder, not a pile. Start at step 1 and climb: plain programs
first, then the standard library, then one idea per service, then
the full combinations. Every `.orb` file below passes
`orbit check`; run status is per-file and measured - limits point at
[Known Limitations](../docs/KNOWN_LIMITATIONS.md), never at
silence.

## The ladder

1. [`hello.orb`](hello.orb) - the smallest program: `fn main`,
   prints, no routes, no database, no `sqlite3.dll`.
2. [`std_strings_demo.orb`](std_strings_demo.orb),
   [`std_files_demo.orb`](std_files_demo.orb),
   [`std_crypto_demo.orb`](std_crypto_demo.orb) - the standard
   library with no services: strings and hashing, a file
   round-trip through `.orbit/tmp`, signed tokens and framing.
3. [`std_imports.orb`](std_imports.orb) - how `import` finds the
   standard library.
4. [`health_service.orb`](health_service.orb) - the first service:
   health probes with no database.
5. [`params_service.orb`](params_service.orb) - routing with path
   parameters, and the rule that static routes win.
6. [`posts_crud.orb`](posts_crud.orb),
   [`sqlite_notes.orb`](sqlite_notes.orb) - persistence: storing
   rows in SQLite, with auth on top in the second.
7. Full services -
   [`blog_api.orb`](blog_api.orb),
   [`file_server.orb`](file_server.orb),
   [`catalog_service.orb`](catalog_service.orb),
   [`sovereignty_service.orb`](sovereignty_service.orb),
   [`orbit_full_expansion.orb`](orbit_full_expansion.orb) - the
   ideas above combined.
8. [`demo-ledger-server.c`](demo-ledger-server.c) - not an Orbit
   demo at all: a C fixture for the cost ledger, built with the
   `gcc`/`cc` line in its own header.

## Available Examples

| File | Purpose | Dependencies | Verified |
|---|---|---|---|
| [`hello.orb`](hello.orb) | Smallest program: `fn main`, prints | None (`sqlite3.dll` NOT needed) | check + build + run (exit 0) |
| [`std_strings_demo.orb`](std_strings_demo.orb) | String shaping, hashing, assertions | None | check |
| [`std_files_demo.orb`](std_files_demo.orb) | File round-trip, logging, uptime clock | None (run from the repo root, scratch goes to `.orbit/tmp`) | check + build + run (exit 0, no litter) |
| [`std_crypto_demo.orb`](std_crypto_demo.orb) | Token signing, verification, framing | None | check |
| [`std_imports.orb`](std_imports.orb) | Canonical `std` import paths | None | check |
| [`health_service.orb`](health_service.orb) | Health, readiness, and metrics endpoints | None | check + build + run (`/health`, `/metrics` 200) |
| [`params_service.orb`](params_service.orb) | Path parameters, static-routes-win rule | None | check |
| [`posts_crud.orb`](posts_crud.orb) | Post CRUD plus `/posts/count` | SQLite (`sqlite3.dll` on Windows) | check + build + run (full cycle: POST, `:id` read, partial PUT, DELETE, count 1→0) |
| [`sqlite_notes.orb`](sqlite_notes.orb) | Notes and user management API | SQLite (`sqlite3.dll` on Windows) | check + build + run (reads, auth 401/403, `:id`, writes) |
| [`blog_api.orb`](blog_api.orb) | Blog API with key-checked publishing | SQLite (`sqlite3.dll` on Windows) | check + build + run (GET, search, POST 201/401/400) |
| [`file_server.orb`](file_server.orb) | File listing, content, raw-body uploads | None | check + build + run (all routes) |
| [`catalog_service.orb`](catalog_service.orb) | Product catalog API | SQLite (`sqlite3.dll` on Windows) | check + build + run (reads and POST 201, 400 on a duplicate id) |
| [`sovereignty_service.orb`](sovereignty_service.orb) | System status and process telemetry API | None | check + build + run (both routes 200) |
| [`orbit_full_expansion.orb`](orbit_full_expansion.orb) | Combined catalog, notes, telemetry, ledger | SQLite (`sqlite3.dll` on Windows) | check + build + run (filtered reads, metrics, `/_ledger/data`) |
| [`demo-ledger-server.c`](demo-ledger-server.c) | C fixture for the cost ledger, not an `.orb` demo | C toolchain only | n/a (build with the command in its header) |

## Details

### `hello.orb`

- Step 1 of the ladder: one `fn main`, two prints, `return 0`.
- Needs nothing: no routes, no models, no database, and on
  Windows no `sqlite3.dll` next to the exe.

### `std_strings_demo.orb`

- Strings demo: shaping (`trim`, `toUpper`), `sha256Hex`, and
  assertions composed in one `main`.
- Imports `std/string`, `std/hash`, `std/test/assert`; no
  services, no database.

### `std_files_demo.orb`

- Files demo: a write/read/remove round-trip, structured logging
  (`info`, `withReq`, `toJsonLine`), and the uptime clock.
- The scratch file is `.orbit/tmp/files_demo.txt`, never the
  current directory: run it from the repository root so the
  scratch lands in the repo's ignored tmp dir, and repeated runs
  leave no litter behind (the file is removed before exit).

### `std_crypto_demo.orb`

- Crypto demo: sign a token with `signHs256`, verify it against
  explicit time, frame it length-prefixed, read the frame back.
- Imports `std/sys/crypto/jwt`, `std/bytes`, `std/string`,
  `std/test/assert`; no services, no database.

### `std_imports.orb`

- Canonical `std` imports resolving via the std search path
  (compiler binary dir, its parent, then the working directory;
  run builds from the repository root).
- Imports `std/sys/term/color` and `std/sys/arena`; no services, no
  database.

### `health_service.orb`

   - Microservice Health & Observability API.
   - Demonstrates runtime metric collection via `system.*()` functions (`uptime()`, `latency_avg_us()`, `active_workers()`, `http_requests_total()`) with dynamic JSON responses assembled via string concatenation.
   - Routes: `GET /health`, `GET /ready`, `GET /metrics`.

### `params_service.orb`

- Path-parameter service: `:id` and `{id}` capture one non-empty
  segment, `*` matches one segment without capturing.
- Static routes win over param patterns covering them
  (`/posts/search` beats `/posts/:id`); query strings keep
  working alongside.
- No models, no database calls, so no `sqlite3.dll` is needed.

### `posts_crud.orb`

- Posts CRUD: custom models get their table created automatically
  at startup, then `create`/`all`/`find`/`update`/`count`/`delete`
  over HTTP.
- Routes: `POST /posts`, `GET /posts`, `GET /posts/:id`,
  `PUT /posts/:id`, `GET /posts/count`, `DELETE /posts/:id`.
- `/posts/count` is declared after `/posts/:id` on purpose: the
  router tries static paths before param patterns, so the static
  route wins and `count` is never read as an `:id`.
- Needs SQLite (`sqlite3.dll` on Windows).
- Try it (PowerShell: single quotes, no backslashes — `\"` escapes
  hide every key from the JSON parser and store an empty row):
  `curl -X POST localhost:3000/posts -H 'Content-Type: application/json' -d '{"id":"a1","title":"hi"}'`,
  then `PUT localhost:3000/posts/a1` with `'{"title":"yo"}'`.

### `blog_api.orb`

- Blog API tutorial service (see the [tutorial](../docs/tutorials/blog-api.md)).
- Demonstrates `model` definitions, `Note.all()`, parameterized
  `Note.where("author_id = ?", …)`, `req.query()` key checks,
  `req.body()` reads, and 200/201/400/401 responses.
- Routes: `GET /posts`, `GET /posts/search`, `POST /posts`,
  `GET /health`.
- Writes are validated and echoed on purpose, not stored: this file
  keeps to one idea. `examples/posts_crud.orb` shows the storing
  version.

### `file_server.orb`

- File server tutorial service (see the [tutorial](../docs/tutorials/file-server.md)).
- Demonstrates static JSON listings, query-driven content,
  raw-body uploads measured with `.len()`, and key checks.
- Routes: `GET /files`, `GET /files/content`, `POST /upload`,
  `GET /health`.
- Multipart uploads and disk persistence are not implemented
  yet; uploads are measured receipts, not stored files.

### `catalog_service.orb`

   - E-commerce & Product Catalog API.
   - Demonstrates `model` definitions, parameterized ORM queries (SQL injection prevention via `?` placeholders), `req.query()` for category filtering, dynamic `req.body()` parsing for `POST`, and error responses with `err`.
   - Routes: `GET /v1/catalog`, `GET /v1/catalog/featured`, `GET /v1/catalog/categories`, `POST /v1/catalog/items`, `GET /v1/catalog/missing`.
   - `Product.create()` stores the row and answers `201`; it answers
     `400` when the `id` is already in the table.

### `sqlite_notes.orb`

   - SQLite-Backed Secure Notes & User Management API.
   - Demonstrates `User` and `Note` models, `req.bearer_token()` authentication, `req.has_role()` authorization, route path parameters with `:id` and `req.param()`, and boolean field usage (`is_private`).
   - Routes: `GET /v1/notes`, `GET /v1/notes/secured`, `POST /v1/notes`, `DELETE /v1/notes/:id`, `GET /health`.
   - Auth needs a row in `sessions` whose `user_id` joins to
     `users.role_name` (see `tests/auth/auth_harness.c`): `401`
     without a token, `403` for a non-admin delete, `200` for an
     admin. `:id` routes match, and `create()`/`delete()` answer
     `true` unless the id is missing or already taken.

### `orbit_full_expansion.orb`

   - Combined service example in current 0.1.0 syntax:
     catalog reads, notes reads, key-checked publish echo,
     health, metrics, and the automatic `/_ledger` table.
   - Routes: `GET /v1/catalog`, `GET /v1/notes`,
     `POST /v1/products`, `GET /health`, `GET /metrics`.

### `sovereignty_service.orb`

   - System status and process telemetry API.
   - Demonstrates system metrics, process information, and health responses.
   - Routes: `GET /v1/sovereign/status`, `GET /v1/sovereign/health`.

### `demo-ledger-server.c`

- A C fixture, not an `.orb` demo: a minimal loopback server on
  the Orbit C runtime for the cost ledger and energy sampler, no
  compiler needed.
- Build with the `gcc`/`cc` line in its own header; it serves
  `GET /hello`, `GET /_ledger`, and `GET /_ledger/data`.

## Running Examples

Build and run with an installed compiler:

```sh
orbit build examples/blog_api.orb -o blog_api
./blog_api 8080
```

With a compiler you built in the repo root, call it by its local path:

```sh
./orbit build examples/blog_api.orb -o blog_api
./blog_api 8080
```

The no-database steps start even simpler (`hello` needs no port
and no setup):

```sh
orbit build examples/hello.orb -o hello
./hello
```

Windows notes:

- The service reads its port from the first argument
  (`.\blog_api.exe 8080`).
- Database examples (`blog_api`, `catalog_service`,
  `orbit_full_expansion`, `posts_crud`, `sqlite_notes`) need
  `sqlite3.dll` next to the exe - without it they exit silently:
  `Copy-Item runtime\vendor\win-x64\sqlite3.dll .`
- The other examples (`hello`, all `std_*` demos,
  `std_imports`, `file_server`, `health_service`,
  `params_service`, `sovereignty_service`) need no dll.
- On first start the service creates `orbit.db` in the working
  directory and seeds demo rows (a couple of seconds);
  restarts are instant.
