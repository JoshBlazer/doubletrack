# Design note: PostgreSQL apps (M10)

Status: **accepted for M10**. Related: ADR 0037 (PostgreSQL snapshots are template
databases), ADR 0004 (snapshot isolation, never transactions), ADR 0029 (SQLite restore),
ADR 0009 (the `doubletrack` environment), RISKS R7.

## Goal

Most production Rails apps run on PostgreSQL. Everything above the database (recorder,
diff, changes, report, repros) is adapter-agnostic already. What's SQLite-specific is how
each twin gets a private database, how the snapshot template is built, and how a session
restores it.

**Exit check** (ROADMAP): shop on PostgreSQL (`SHOP_DATABASE=postgresql`) in CI against a
Postgres service:
* the same session replayed twice on one twin gives identical normalized traces (the M2
  check);
* `doubletrack run` finds shop's change with a verified reproduction (the M3/M4 checks), and
  the generated test passes on the current Rails and fails on the next one, run for real;
* every database Doubletrack created is gone afterwards.

## Which database a twin uses

The twin decides, because only the app's process can read `config/database.yml` (ERB,
credentials, `DATABASE_URL` conventions). After `config/application.rb` loads and before
the environment loads, the worker reads the app's **test** configuration:
* SQLite (or no test config): unchanged. The coordinator's `DATABASE_URL` points at
  `<work>/<role>.sqlite3`.
* PostgreSQL: the worker replaces `DATABASE_URL` with the test config's connection (host,
  port, username, password, or its `url`) and a private database name:
  `dt_<10 hex of SHA-256(work dir)>_<role>`, which stays under 63 characters and is unique
  per run.
* Anything else, or several databases: refused, as today.

`hello` gains `database: {"adapter", "name"}`, and the report shows the adapter.

## Snapshots (ADR 0037)

```
build(template_path)   control A, once per snapshot kind
  name = "dt_<hash(work)>_t_<12 hex of SHA-256(template_path)>"
  DROP DATABASE IF EXISTS name WITH (FORCE); CREATE DATABASE name
  connect to it; load db/schema.rb (+ seeds, + fixtures); count rows; disconnect
  → {"template_path", "adapter" => "postgresql", "template" => name, "bytes" => pg_database_size,
     "sha256" => SHA-256 of the row counts, "tables"}

restore(template_path) every twin, before every session
  disconnect the app's pool
  DROP DATABASE IF EXISTS own WITH (FORCE)    (FORCE ends the app's own threads' connections, R18)
  CREATE DATABASE own TEMPLATE template
  the next query reconnects
```

Admin statements go through a separate `PG::Connection` to the `postgres` maintenance
database, with the same credentials. `WITH (FORCE)` needs PostgreSQL 13 or newer. The twin
checks the server version at boot and refuses older servers with a clear message.

**Cleanup.** On `shutdown`, each twin drops its own database, and control A also drops the
templates it built. A twin that crashes leaves databases named `dt_<hash>_…` (the
coordinator has no PostgreSQL client, so it can't sweep them); drop them with
`DROP DATABASE`.

## Reproductions

A SQLite repro ships a copy of the template file. For PostgreSQL, the repro's snapshot is a
small recipe file, `snapshots/<hash>.pg.json`:
`{"adapter": "postgresql", "seed": 7, "seeds": false, "fixtures": true}`. When a repro twin
restores a recipe it hasn't built yet, it builds the template from the app's schema (and
seeds and fixtures) with that seed, then restores as usual. Schema, seeds and fixtures are
deterministic under a seed, so the rebuilt template matches the run's as long as those files
haven't changed (stated in the generated file's header).

## doctor

The database check accepts PostgreSQL when the bundle has `pg`. The boot check fails on a
server older than 13, since the twin refuses it at boot.

## Limitations

* `WITH (FORCE)` needs PostgreSQL 13+.
* Restoring costs time: measured on shop under WSL2, `DROP … WITH (FORCE)` plus
  `CREATE … TEMPLATE` took 300–700 ms per twin, about 2 s per session with three twins
  (walkthrough m10). This replaces the 50–300 ms guessed before measuring.
* Database-side time (`now()`, `CURRENT_TIMESTAMP` defaults) isn't frozen, as with SQLite.
* MySQL isn't supported.
* A PostgreSQL repro rebuilds its template from the current schema, so it can drift if
  `db/schema.rb`, seeds or fixtures change after the run.
