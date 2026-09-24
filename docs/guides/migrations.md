# Guide: Database Migrations (the honest story)

There is no migration system in 0.1.0. No schema versioning, no
upgrade path, no `orbit migrate` command. This guide describes
the manual practice that works today, what can go wrong, and
what a real story would need. If you're storing anything you
can't afford to lose, read the whole page before deploying.

## What the runtime actually does

On startup, `orbit_db_init` opens `orbit.db` in the service's
working directory and runs `CREATE TABLE IF NOT EXISTS` for
the four built-in tables (`notes`, `products`, `users`,
`sessions`); the compiler additionally emits one `CREATE TABLE
IF NOT EXISTS` per model in your program, so a `Post` model gets
a real table. When `products` is empty it inserts the demo seed
rows. That's the current schema story:

- New tables are created from model fields, but existing tables
  are never altered. Adding a field to a model changes nothing
  on disk.
- There is no version recorded anywhere. The database can't tell
  you which code created it.

## The practice that works today

1. **Treat the schema as fixed.** Build only on the four
   tables above, with the columns the runtime creates. Read
   them as the contract; the model block in your `.orb` file
   must match them field for field.
2. **One database file per service directory.** The file lives
   in the working directory, so a systemd `WorkingDirectory`
   or a deployment folder pins it. Never run two services
   against one `orbit.db` - locking behavior there is
   UNTESTED, and silent corruption is the failure mode you
   won't see until restore time.
3. **Back up the file, not the rows.** Stop the service
   (Windows stop is immediate kill - plan for that), copy
   `orbit.db`, start again. SQLite backup API integration is
   future work.
4. **Schema change = new file + export/import.** To change
   shape today: stop the service, dump with the `sqlite3`
   shell, create the new layout by hand, load, and point the
   service at it. Test the whole round trip on a copy first.
5. **Seed data is demo data.** The built-in seed rows
   (`prod_101…`, `note_101…`) land in every fresh database.
   If they don't belong in production, delete them as part of
   provisioning - and note that provisioning step in your own
   runbook.

## What can go wrong

- **Writes fail silently-ish.** `create()` returns `false`;
  your handler's `400` branch runs. If you don't have that
  branch, the client sees an empty reply. Always code the
  failure branch.
- **Two writers, one file.** UNTESTED and explicitly out of
  scope - concurrent writes from two processes against one
  `orbit.db` have no contract. One writer per file.
- **Windows stop loses in-flight writes.** Stop is
  `TerminateProcess`. A write in flight when you stop the
  service may or may not have landed. Quiesce traffic first,
  then stop, then back up.

## What a real migration story needs

Versioned schema files, an upgrade runner that applies them in
order inside a transaction, a `down` path or a tested restore,
and a check the service refuses to start on a newer-than-known
schema. That's tracked work (see `STAB-6` in ENGINEERING.md),
not a promise with a date. Until it lands, this page is the
whole contract - I'd rather you be annoyed at the manual steps
than surprised by a lost table.
