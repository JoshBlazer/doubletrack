# Architecture (draft, M2)

This document describes the intended architecture. Sections are marked **[built]** once
code exists and a test proves it; everything else is design.

```
            ┌──────────── Coordinator (CLI process) ─────────────┐
 sessions ─▶│ load → schedule → replay → diff → denoise → cluster │──▶ results/*.json ──▶ report
            └──────┬───────────────────┬───────────────────┬──────┘
                   │ NDJSON on fd 3/4  │                   │
           ┌───────▼──────┐    ┌───────▼──────┐    ┌───────▼──────┐
           │ Control A    │    │ Control A′   │    │ Candidate B  │
           │ old Rails    │    │ old Rails    │    │ new Rails    │
           └──────────────┘    └──────────────┘    └──────────────┘
```

## Components

| Directory | Responsibility | Status |
|---|---|---|
| `lib/doubletrack/protocol/` | Framing, message envelope, schema version | **[built, M0]** |
| `lib/doubletrack/coordinator/` | Spawning twins, boot/request timeouts, crash detection, scheduling | **[built, M0: spawn + timeouts]** |
| `lib/doubletrack/twin/` | Worker loop, Rails boot, `doubletrack` env overlay, determinism, snapshot restore | **[built, M0–M2]** |
| `lib/doubletrack/recorder/` | Instrumentation subscribers and HTTP interceptor → traces | **[built, M1]** |
| `lib/doubletrack/session.rb` | Session files: strict parsing, defaults, per-session seeds | **[built, M2]** |
| `lib/doubletrack/normalize/` | SQL, HTML, JSON, header normalizers | **[built, M2: trace volatiles]**; M3: bodies, SQL |
| `lib/doubletrack/diff/` | Structural diff, noise mask, clustering, severity | M3 |
| `lib/doubletrack/report/` | Static site generator | M3 |
| `lib/doubletrack/specgen/` | Reproduction spec generation | M4 |
| `lib/doubletrack/baseline/` | `accept` and baseline filtering | M4 |
| `lib/doubletrack/traffic/` | Test-derived capture; later fuzzer and middleware | M5 |
| `lib/doubletrack/cli/` | Commands, output, exit codes | M0 skeleton |
| `lib/doubletrack/bisect/`, `defaults/` | Later layers L1/L2 | – |

## Process model **[built, M0]**

* The coordinator is the `doubletrack` CLI process, running on the gem's own bundle.
* Each twin is a separate Ruby process (ADR 0002) running
  `ruby lib/doubletrack/twin/main.rb` with `chdir` = app root, `BUNDLE_GEMFILE` =
  `Gemfile` (A, A′) or `Gemfile.next` (B), inside `Bundler.with_unbundled_env`.
* The twin loads only the standard library until the app's bundle is set up; Doubletrack
  is never added to the app's Gemfile.
* Twins boot once and are reused across sessions.

## Protocol **[built, M0]**

See `docs/design/protocol.md`. NDJSON over fds 3 (in) / 4 (out). App stdout/stderr go
to `<work_dir>/twin-<role>.log`.

## Twin environment **[built, M0]**

`RAILS_ENV=doubletrack`, overlaid from the gem (ADR 0009): the app's `test.rb` plus
Doubletrack overrides. The database comes from `DATABASE_URL` pointing at a private SQLite
file per twin.

## Session model **[built, M2]**

A session is an ordered list of requests sharing cookies, replayed from one database
snapshot through `ActionDispatch::Integration::Session` against `Rails.application`
(`docs/formats/session.md`).

## Snapshots **[built, M2]**

Control A builds one template (`db/schema.rb`, optionally `db/seeds.rb`, then
`VACUUM INTO`). Before each session, every twin copies it over its working database and
ActiveRecord reconnects. No transaction rollback (ADR 0004). Design:
`docs/design/replay.md`.

## Determinism controls **[built, M2]**

* Time is frozen per request at `started_at + offset_ms` by Doubletrack's own clock
  (ADR 0015).
* `Kernel#rand` is seeded per session from the run seed and the session id.
* `SecureRandom` is left alone: the normalizer removes the values it knows about, and
  noise cancellation absorbs the rest.
* ActiveJob uses `:test`, and enqueued jobs are performed inline after the request
  (ADR 0014). ActionMailer uses `:test`.
* Outbound HTTP is intercepted at `Net::HTTP` (ADR 0012).

## Side-effect recorder **[built, M1]**

Per-request subscriptions to `sql.active_record` (writes only), `enqueue*.active_job`,
`deliver.action_mailer`, `cache_write`/`cache_delete.active_support`, plus the HTTP
interceptor and the response. Always unsubscribed in `ensure`. Output: a versioned trace
per request (`docs/formats/trace.md`). Design: `docs/design/recorder.md`. The cache is a
fresh `:memory_store` cleared per session (ADR 0011); outbound HTTP goes through a
`Net::HTTP` interceptor installed before boot (ADR 0012).

## Normalization, diff, noise, clustering (M2–M3)

Normalizers are idempotent and property-tested. The A vs A′ diff produces a per-field-path
noise mask, and A vs B differences outside the mask are findings. Fingerprint = kind +
location + normalized change shape, with identical fingerprints merged across sessions.
Severity rules live in one module.

## Data formats

All versioned, documented in `docs/formats/` as they are built:
`sessions/*.jsonl`, `results/<run_id>/traces/*.json`, `results/<run_id>/findings.json`,
`results/<run_id>/run.json`.
