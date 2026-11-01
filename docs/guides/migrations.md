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
program does not re-apply. A failed statement prints `orbit: migrations
failed to apply` and exits 1. Two writers against one database file remain
out of scope.

`model`-derived `CREATE TABLE IF NOT EXISTS` still runs automatically as
before.

## The practice that works today

1. **One database file per service directory.** The default file is
   `.orbit/data/app.db` under the project directory (`orbit start`
   creates it. A legacy `./orbit.db` is moved there once). Never run
   two services against one file - locking behavior there is
   UNTESTED, and silent corruption is the failure mode you
   won't see until restore time.
2. **Back up the file, not the rows.** Stop the service
   (Windows stop is immediate kill - plan for that), copy
   `.orbit/data/app.db`, start again. SQLite backup API integration is
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
  payload has no usable fields. Your handler's `400` branch runs
  and, without it, the client sees an empty reply. Always code
  the failure branch - a re-post of a stored id lands there.
- **Two writers, one file.** UNTESTED and explicitly out of
  scope - concurrent writes from two processes against one
  database file have no contract. One writer per file.
- **A Windows stop that finds no channel is a kill.** The graceful ask sets
  `Local\orbit-stop-<pid>`, and a server that never reached its start has no
  such name, so the stop falls back to `TerminateProcess`. A write in flight
  then may or may not have landed. Quiesce traffic first,
  then stop, then back up.

## Rolling back

A `migrations down "<SQL>"` line undoes the forward migration at the same
position. At startup, `ORBIT_MIGRATE_DOWN=<version>` rolls back every applied
version above that number, newest first, one transaction per version, removes
their rows from `_orbit_migrations`, and stops: the forward set does not run
in the same start, so the next run applies it again. `-1` rolls back
everything. A version with no down line, a failing statement, or a database
holding versions this program does not declare all fail startup with a
message naming the version.

A database whose schema is newer than the program is refused. If
`_orbit_migrations` holds a version this program does not declare, startup
prints the version and exits non-zero, instead of running old code against
columns it cannot describe. That refusal is `test_newer_schema_is_refused` in
`runtime/test_migrations.c`, and `test_down_rolls_back` pins the rollback.

## Running migrations without starting the service

`orbit migrate app.orb` builds the program once into `.orbit/migrate` and runs
only the database block: it applies the forward migrations, or rolls back when
`ORBIT_MIGRATE_DOWN=<version>` is set, then exits with the migration result. It
never listens, so it is the command for a deploy step that must not start the
service.
