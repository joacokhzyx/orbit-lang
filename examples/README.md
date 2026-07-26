# Orbit Examples

This directory contains real-world, production-shaped service examples built with the Orbit programming language.

## Available Examples

1. **`catalog_service.orb`**
   - E-commerce & Product Catalog API.
   - Demonstrates `model` definitions, parameterized ORM queries (SQL injection prevention via `?` placeholders), `req.query()` for category filtering, dynamic `req.body()` parsing for `POST`, and error responses with `err`.
   - Routes: `GET /v1/catalog`, `GET /v1/catalog/featured`, `GET /v1/catalog/categories`, `POST /v1/catalog/items`, `GET /v1/catalog/missing`.

2. **`health_service.orb`**
   - Microservice Health & Observability API.
   - Demonstrates runtime metric collection via `system.*()` functions (`uptime()`, `latency_ms()`, `active_workers()`, `http_requests_total()`) with dynamic JSON responses assembled via string concatenation.
   - Routes: `GET /health`, `GET /ready`, `GET /metrics`.

3. **`sqlite_notes.orb`**
   - SQLite-Backed Secure Notes & User Management API.
   - Demonstrates `User` and `Note` models, `req.bearer_token()` authentication, `req.has_role()` authorization, route path parameters with `:id` and `req.param()`, and boolean field usage (`is_private`).
   - Routes: `GET /v1/notes`, `GET /v1/notes/secured`, `POST /v1/notes`, `DELETE /v1/notes/:id`, `GET /health`.

4. **`orbit_full_expansion.orb`**
   - Comprehensive full-feature Orbit service example.
   - Demonstrates server configuration (`port`, `cors`, `db`, `env`), `type` aliases, `Email`/`URL` typed model fields, `@auth`/`@admin` decorators, `try`/`catch` error handling around `fetch()`, `cache.get()`/`cache.set()` with null-check guarding, `every` scheduled tasks, file upload via `req.file().save()`, and `=>` arrow-route syntax.
   - Routes: `GET /v1/catalog`, `GET /v1/external-rates`, `POST /v1/upload-avatar`, `POST /v1/products`.

## Running Examples

Compile and run with the Orbit compiler:

```sh
orbit build examples/catalog_service.orb
```

Or run directly:

```sh
orbit run examples/catalog_service.orb
```
