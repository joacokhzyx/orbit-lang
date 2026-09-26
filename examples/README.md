# Orbit Examples

Service examples you can build and run. Each one shows a
combination of HTTP, data access, auth, or runtime features.
Every file below passes `orbit check` and `orbit build` with
the `0.1.0` fixed-point compiler; run status is per-file and
honest - limits point at [Known Limitations](../docs/KNOWN_LIMITATIONS.md),
never at silence.

## Available Examples

| File | Purpose | Dependencies | Verified |
|---|---|---|---|
| [`blog_api.orb`](blog_api.orb) | Blog API with key-checked publishing | SQLite (`sqlite3.dll` on Windows) | check + build + run (GET, search, POST 201/401/400) |
| [`file_server.orb`](file_server.orb) | File listing, content, raw-body uploads | None | check + build + run (all routes) |
| [`catalog_service.orb`](catalog_service.orb) | Product catalog API | SQLite (`sqlite3.dll` on Windows) | check + build + run (reads verified; writes answer 400) |
| [`health_service.orb`](health_service.orb) | Health, readiness, and metrics endpoints | None | check + build + run (`/health`, `/metrics` 200) |
| [`sqlite_notes.orb`](sqlite_notes.orb) | Notes and user management API | SQLite (`sqlite3.dll` on Windows) | check + build + run (reads verified; auth, `:id`, writes limited - see below) |
| [`orbit_full_expansion.orb`](orbit_full_expansion.orb) | Combined catalog, notes, telemetry, ledger | SQLite (`sqlite3.dll` on Windows) | check + build + run (filtered reads, metrics, `/_ledger/data`) |
| [`sovereignty_service.orb`](sovereignty_service.orb) | System status and process telemetry API | None | check + build + run (both routes 200) |

## Details

### `blog_api.orb`

- Blog API tutorial service (see the [tutorial](../docs/tutorials/blog-api.md)).
- Demonstrates `model` definitions, `Note.all()`, parameterized
  `Note.where("author_id = ?", …)`, `req.query()` key checks,
  `req.body()` reads, and 200/201/400/401 responses.
- Routes: `GET /posts`, `GET /posts/search`, `POST /posts`,
  `GET /health`.
- Writes are validated and echoed, not stored
  (`create()` returns `false` in 0.1.0).

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
   - Limit: `Product.create()` returns `false` in 0.1.0, so
     `POST /v1/catalog/items` answers `400` today.

### `health_service.orb`

   - Microservice Health & Observability API.
   - Demonstrates runtime metric collection via `system.*()` functions (`uptime()`, `latency_avg_us()`, `active_workers()`, `http_requests_total()`) with dynamic JSON responses assembled via string concatenation.
   - Routes: `GET /health`, `GET /ready`, `GET /metrics`.

### `sqlite_notes.orb`

   - SQLite-Backed Secure Notes & User Management API.
   - Demonstrates `User` and `Note` models, `req.bearer_token()` authentication, `req.has_role()` authorization, route path parameters with `:id` and `req.param()`, and boolean field usage (`is_private`).
   - Routes: `GET /v1/notes`, `GET /v1/notes/secured`, `POST /v1/notes`, `DELETE /v1/notes/:id`, `GET /health`.
   - Limits in 0.1.0: `/secured` returns an empty reply
     (`bearer_token` gap), `:id` routes never match (router
     404), and `create()`/`delete()` return `false`.

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

Windows notes:

- The service reads its port from the first argument
  (`.\blog_api.exe 8080`).
- Database examples need `sqlite3.dll` next to the exe -
  without it they exit silently:
  `Copy-Item runtime\vendor\win-x64\sqlite3.dll .`
- On first start the service creates `orbit.db` in the working
  directory and seeds demo rows (a couple of seconds);
  restarts are instant.
