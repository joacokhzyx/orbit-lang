# Orbit examples

These examples use the public `orbit` compilation path and model small service
endpoints a team could deploy behind a reverse proxy. They intentionally keep
transport, environment management, migrations, and observability outside the
example: those belong to the service's deployment configuration.

Build an example with:

```sh
orbit build examples/health_service.orb
```

- `health_service.orb` — health and readiness endpoints for an orchestration probe.
- `catalog_service.orb` — a small catalog API shape with explicit HTTP outcomes.
- `sqlite_notes.orb` — the model shape for a SQLite-backed notes service.

The native backend is not used by these examples and is not a supported deployment
target. See [STATUS.md](../STATUS.md) before adapting an example for production.
