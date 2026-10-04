# Guide: Database Migrations

There IS a migration system now: top-level `migrations "<SQL>"` lines run
at startup through `orbit_run_migrations`:

```orbit
model Note { id: string, title: string }

migrations "ALTER TABLE notes ADD COLUMN rank INTEGER"
migrations "CREATE INDEX IF NOT EXISTS ix_notes_rank ON notes(rank)"
```

Each line runs once, in declaration order, inside a transaction, and a
`_orbit_migrations` table records the applied versions. Rerunning the
program does not re-apply; a failed statement prints `orbit: migrations
failed to apply` and exits 1; two writers against one `orbit.db` remain
out of scope.

`model`-derived `CREATE TABLE IF NOT EXISTS` still runs automatically as
before.

## The practice that works today

1. **One database file per service directory.** The file lives
   in the working directory, so a systemd `WorkingDirectory`
   or a deployment folder pins it. Never run two services
   against one `orbit.db` - locking behavior there is
   UNTESTED, and silent corruption is the failure mode you
   won't see until restore time.
2. **Back up the file, not the rows.** Stop the service
   (Windows stop is immediate kill - plan for that), copy
   `orbit.db`, start again. SQLite backup API integration is
   future work.
3. **Additive changes via `migrations`.** ALTER ADD COLUMN,
   CREATE INDEX, and other forward-only DDL belong in one
   `migrations "..."` line per change, appended at the end of
   the list. Never edit or delete an existing line: the runner
   versions by position, so renumbering an old entry reruns it
   on existing databases.
4. **Seed data is demo data.** The built-in seed rows
   (`prod_101…`, `note_101…`) land in every fresh database.
   If they don't belong in production, delete them as part of
   provisioning - and note that provisioning step in your own
   runbook.

## What can go wrong

- **Writes fail silently-ish.** `create()` answers `false` when
  the `id` is already in the table (the primary key) or the
  payload has no usable fields; your handler's `400` branch runs
  and, without it, the client sees an empty reply. Always code
  the failure branch - a re-post of a stored id lands there.
- **Two writers, one file.** UNTESTED and explicitly out of
  scope - concurrent writes from two processes against one
  `orbit.db` have no contract. One writer per file.
- **Windows stop loses in-flight writes.** Stop is
  `TerminateProcess`. A write in flight when you stop the
  service may or may not have landed. Quiesce traffic first,
  then stop, then back up.

## What is deliberately not there

`down` migrations, a `schema_version` check that refuses newer-than-known,
and `orbit migrate` as a standalone command do not exist; migrations
run at startup, inside the process, in order. That is the whole of the
contract, and `runtime/test_migrations.c` pins exactly this shape.
