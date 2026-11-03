# Design note: session replay (M2)

Status: **accepted for M2**. Related: ADR 0004 (snapshots, not rollback), ADR 0014
(jobs performed inline), ADR 0015 (Doubletrack's own clock), ADR 0016 (protocol
schema_version 3), `docs/formats/session.md`, `docs/formats/trace.md` (trace_version 2).

## Goal

Replaying one session twice must give the same result. That holds whether the two replays
run on the same twin or on two twins of the same Rails version. Everything a request can
observe has to be reset or pinned first: the database, the cache, the clock, the RNG,
delivered mail, the job queue, and outbound HTTP. Without that, the three-way noise
canceller in M3 has nothing stable to compare against.

**Exit check:** `spec/integration/replay_spec.rb` replays the same multi-request session
twice on control A and once on control A′. The three normalized traces must be identical.
The spec runs on both Rails versions.

## Snapshots (ADR 0004)

```
prepare_snapshot (to control A only)          run_session (to every twin)
------------------------------------          ---------------------------
disconnect ActiveRecord                       disconnect ActiveRecord
delete working db (+ -wal, -shm, -journal)    delete working db (+ -wal, -shm, -journal)
connect → empty database                      copy template → working db
load db/schema.rb                             reconnect (lazily, on first query)
optionally load db/seeds.rb (frozen clock,
  seeded rand)
VACUUM INTO <work_dir>/template.sqlite3
reply {template_path, bytes, sha256, tables}
```

* One twin builds the template and every twin restores from it. That way A, A′ and B all
  start from **byte-identical** data, even though B runs a different Rails version.
  Building it once per twin would let a Rails change in schema loading leak into every
  session.
* `VACUUM INTO` writes a consistent, self-contained file even when the source is in WAL
  mode. The template is never opened again after it's written, so a plain file copy of
  it is safe. The working database's WAL/SHM files are deleted before the copy, because
  a stale WAL would be replayed onto the fresh copy.
* `ActiveRecord::Base.connection_pool.disconnect!` works on Rails 7.1–8.1. Multiple
  databases are out of scope (RISKS R7): `prepare_snapshot` refuses apps with more than
  one database config.
* The boot-time schema load from M0/M1 (the stopgap) is removed. A twin's database stays
  empty until its first `run_session` with a snapshot.
* A session **without** a `snapshot` runs against whatever state the working database
  has. The spike and unit tests use that. `doubletrack run` always sends one.

## Determinism controls

Applied by the twin around each session, in this order:

1. **Reset in-memory state:** `Rails.cache.clear`, mail deliveries, the test adapter's
   enqueued/performed jobs (as in M1).
2. **Restore the snapshot** (above).
3. **Seed randomness:** `Kernel.srand(session["seed"])`. The coordinator derives the
   seed per session as `SHA256("#{run_seed}:#{session_id}")[0, 16].to_i(16)`, so a
   session's seed doesn't depend on its position in the run.
4. **Freeze the clock** (ADR 0015). Request *i* runs with the time frozen at
   `started_at + offset_ms_i`. `offset_ms` comes from the session file and defaults to
   `1000 * i`. Jobs performed after a request run at the same instant, or at their
   `scheduled_at` if that's later.
5. **Outbound HTTP** stays as in M1: stubs from the session, otherwise a synthetic 503.

`SecureRandom` is not controlled (ADR 0015). Values derived from it (session IDs, CSRF
tokens, `x-request-id`, `has_secure_token`) are handled in two ways. The normalizer
removes the ones we know about. Any others vary between A and A′, so M3's noise mask
absorbs them.

### Clock API (`lib/doubletrack/twin/clock.rb`, standard library only)

```ruby
Doubletrack::Twin::Clock.install!            # prepends into Time/Date/DateTime singletons; idempotent
Doubletrack::Twin::Clock.freeze_at(time) { } # Time.now, Time.new (no args), Date.today, DateTime.now
                                             # return `time` inside the block; nests; restores on exit
Doubletrack::Twin::Clock.frozen              # => Time or nil
```

It is not thread-local. A twin runs one request at a time, and app threads spawned
during a request should see the frozen time too. Monotonic clocks (`Process.clock_gettime`)
are left alone: `x-runtime` and `duration_ms` measure real elapsed time, and the
normalizer drops them.

## Jobs performed inline (ADR 0014)

After the request returns, the recorder performs every job it saw enqueued, in order,
until the queue is empty or `MAX_PERFORMED_JOBS = 25` is reached. Jobs enqueued by jobs
are included. Each job runs from its serialized form (`ActiveJob::Base.execute`), so
arguments make the same round trip through GlobalID that they would in production. Each
performed job gets an entry in `trace["performed_jobs"]` with its own side-effect
channels (`sql_writes`, `jobs`, `mail`, `cache`, `http`) and its `exception`, if any.
The request's own channels stay exactly as in M1, so request side effects and job side
effects never mix.

Opt out per run with `perform_jobs: false`, from `doubletrack.yml` or the run_session
options. Jobs are then recorded as enqueued, as in M1.

## Cookies across requests

All requests in a session already share one `ActionDispatch::Integration::Session`, so
cookies persist between them. After each request, the trace records the decoded Rack
session (`trace["session"]`). The session cookie itself is encrypted with a random IV,
so its raw value changes on every replay, while the decoded contents are what a user
actually carries. The normalizer then replaces the session cookie's value with
`"<session>"`.

## Normalization in M2 (minimal; M3 extends it)

`Doubletrack::Normalize::Trace.call(trace, session_cookie:)` returns a new Hash and never
mutates its input. It is idempotent: `call(call(t)) == call(t)`.

* Drops `duration_ms` and `deprecations`: both are evidence, never diffed.
* Response headers: drops `x-request-id` and `x-runtime`. Parses `set-cookie` into
  `response.set_cookies` (name → `{value, attributes}`) and replaces the session
  cookie's value.
* `session`: drops `session_id` and `_csrf_token`.
* `exception`: keeps `class` and `message`; drops `backtrace`, since gem paths differ
  between bundles. Replaces object addresses (`0x000…`) with `0x…`.
* The same rules apply to every entry in `performed_jobs`.

## Protocol schema_version 3 (ADR 0016)

* `hello` adds `routes[]` (`verb`, `path`, `name`, `controller`, `action`) and
  `session_cookie`.
* `prepare_snapshot` is implemented. Payload: `template_path`, `seeds` (bool),
  `started_at`, `seed`. Result: `template_path`, `bytes`, `sha256`, `tables` (name →
  row count).
* `run_session` payload: `session` gains `snapshot` (template path or null),
  `started_at`, `seed`, and per-request `offset_ms`. A new `options` object carries
  `perform_jobs`.
* Traces are trace_version 2. New keys: `route`, `time`, `session`, `deprecations`,
  `performed_jobs`.

## Tests written before the implementation

1. `spec/doubletrack/twin/clock_spec.rb`: frozen `Time.now`/`Time.new`/`Date.today`/
   `DateTime.now`; `Time.now(in:)`; nesting and restore; untouched outside the block;
   returned objects are fresh copies, so mutating one can't change the clock.
2. `spec/doubletrack/session_spec.rb`: parses `sessions/*.jsonl`; rejects bad lines
   with file:line; fills defaults (`offset_ms`, `method`); derives per-session seeds
   stable under reordering.
3. `spec/doubletrack/normalize/trace_spec.rb`: the rules above, plus properties:
   idempotence, no mutation of the input, invariance under the volatile fields.
4. `spec/integration/replay_spec.rb`: **the exit check**, plus snapshot isolation (row
   ids restart at 1 in every session), a cookie carried across requests, a frozen clock
   visible in `created_at`, and a job performed inline with its mail recorded.
