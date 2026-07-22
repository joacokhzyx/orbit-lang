# Orbit Examples

This directory contains real-world, production-shaped service examples built with the Orbit programming language.

## Available Examples

1. **`catalog_service.orb`**
   - E-commerce & Product Catalog API.
   - Includes data models for `Product` and realistic JSON payloads for catalog listings, featured products, categories, item creation (`POST`), and error handling (`404`).

2. **`health_service.orb`**
   - Microservice Health & Observability API.
   - Includes `/health` (full component statuses), `/ready` (load-balancer probe), and `/metrics` (request counts, P50/P95/P99 latencies, active workers).

3. **`sqlite_notes.orb`**
   - SQLite-Backed Secure Notes & User Management API.
   - Includes `User` and `Note` models, authenticated endpoint handling (`401 Unauthorized`), admin authorization checks (`403 Forbidden`), and notes CRUD operations.

## Running Examples

Start an example service in development mode:

```sh
orbit dev examples/catalog_service.orb
```

Or compile a standalone executable binary:

```sh
orbit build examples/health_service.orb
```
