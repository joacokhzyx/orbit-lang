# Orbit Examples

This directory contains service examples built with the Orbit programming language. Each example demonstrates a specific combination of HTTP, data access, authentication, or runtime features. Treat examples as source references until they pass the current compiler and runtime gates.

## Available Examples

| File | Purpose | Dependencies | Main coverage |
|---|---|---|---|
| [`catalog_service.orb`](catalog_service.orb) | Product catalog API | SQLite | Models, filtered queries, request body, success and error responses |
| [`health_service.orb`](health_service.orb) | Health, readiness, and metrics endpoints | None documented | Runtime metrics and JSON responses |
| [`sqlite_notes.orb`](sqlite_notes.orb) | Notes and user management API | SQLite | Models, bearer tokens, roles, path parameters, mutation |
| [`orbit_full_expansion.orb`](orbit_full_expansion.orb) | Broad language and service example | SQLite, network access, file storage | Configuration, aliases, decorators, cache, fetch, uploads, schedules |
| [`sovereignty_service.orb`](sovereignty_service.orb) | System status and process telemetry API | None documented | System metrics, process information, service health |

## Details

### `catalog_service.orb`

   - E-commerce & Product Catalog API.
   - Demonstrates `model` definitions, parameterized ORM queries (SQL injection prevention via `?` placeholders), `req.query()` for category filtering, dynamic `req.body()` parsing for `POST`, and error responses with `err`.
   - Routes: `GET /v1/catalog`, `GET /v1/catalog/featured`, `GET /v1/catalog/categories`, `POST /v1/catalog/items`, `GET /v1/catalog/missing`.

### `health_service.orb`

   - Microservice Health & Observability API.
   - Demonstrates runtime metric collection via `system.*()` functions (`uptime()`, `latency_ms()`, `active_workers()`, `http_requests_total()`) with dynamic JSON responses assembled via string concatenation.
   - Routes: `GET /health`, `GET /ready`, `GET /metrics`.

### `sqlite_notes.orb`

   - SQLite-Backed Secure Notes & User Management API.
   - Demonstrates `User` and `Note` models, `req.bearer_token()` authentication, `req.has_role()` authorization, route path parameters with `:id` and `req.param()`, and boolean field usage (`is_private`).
   - Routes: `GET /v1/notes`, `GET /v1/notes/secured`, `POST /v1/notes`, `DELETE /v1/notes/:id`, `GET /health`.

### `orbit_full_expansion.orb`

   - Comprehensive full-feature Orbit service example.
   - Demonstrates server configuration (`port`, `cors`, `db`, `env`), `type` aliases, `Email`/`URL` typed model fields, `@auth`/`@admin` decorators, `try`/`catch` error handling around `fetch()`, `cache.get()`/`cache.set()` with null-check guarding, `every` scheduled tasks, file upload via `req.file().save()`, and `=>` arrow-route syntax.
   - Routes: `GET /v1/catalog`, `GET /v1/external-rates`, `POST /v1/upload-avatar`, `POST /v1/products`.

### `sovereignty_service.orb`

   - System status and process telemetry API.
   - Demonstrates system metrics, process information, and health responses.
   - Routes: `GET /v1/sovereign/status`, `GET /v1/sovereign/health`.

## Running Examples

Compile and run with an installed Orbit compiler:

```sh
orbit build examples/catalog_service.orb
```

When using a compiler built in the repository root, call it by its local path:

```sh
./orbit build examples/catalog_service.orb -o catalog_service
./catalog_service
```
