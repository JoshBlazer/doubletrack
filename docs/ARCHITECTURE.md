# Architecture

How Doubletrack is built, as of M5. Sections are marked **[built]** once code exists and
a test proves it; anything unmarked is design for a later layer.

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
| `lib/doubletrack/coordinator/` | Spawning twins, boot/request timeouts, crash detection, scheduling | **[built, M0–M3: spawn, timeouts, `Run` orchestration]** |
| `lib/doubletrack/twin/` | Worker loop, Rails boot, `doubletrack` env overlay, determinism, snapshot restore | **[built, M0–M2]** |
| `lib/doubletrack/recorder/` | Instrumentation subscribers and HTTP interceptor → traces | **[built, M1]** |
| `lib/doubletrack/session.rb` | Session files: strict parsing, defaults, per-session seeds | **[built, M2]** |
| `lib/doubletrack/normalize/` | SQL, HTML and JSON normalizers; `trace.rb` normalizes a whole trace (headers, cookies, volatile fields) | **[built, M2–M3]** |
| `lib/doubletrack/diff/` | Structural diff, noise mask, clustering, severity | **[built, M3]** |
| `lib/doubletrack/results.rb`, `config.rb` | Results directory (traces, findings, run.json), `doubletrack.yml` | **[built, M3]** |
| `lib/doubletrack/report/` | Static site generator | **[built, M3]** |
| `lib/doubletrack/specgen/`, `specgen.rb` | Repro verification and minimization on the live twins, RSpec/Minitest rendering | **[built, M4]** |
| `lib/doubletrack/repro.rb` | Helper the generated specs call, inside the user's test process: boots one twin, replays, normalizes | **[built, M4]** |
| `lib/doubletrack/baseline.rb` | `doubletrack.baseline.yml`: strict load, `accept`, marking accepted findings | **[built, M4]** |
| `lib/doubletrack/capture.rb`, `capture/` | Test-derived capture: probe (in the test process), record builder, assembler, runner | **[built, M5]** |
| `lib/doubletrack/traffic/` | Later: fuzzer and production middleware | L3 |
| `lib/doubletrack/cli.rb` | Commands, output, exit codes | **[built: `run`, `report`, `accept`, `capture`]**; others report their milestone |
| `lib/doubletrack/bisect/`, `defaults/` | Later layers L1/L2 | – |

## Process model **[built, M0]**

* The coordinator is the `doubletrack` CLI process, running on the gem's own bundle.
* Each twin is a separate Ruby process (ADR 0002) running
  `ruby lib/doubletrack/twin/main.rb` with `chdir` = app root, `BUNDLE_GEMFILE` =
  `Gemfile` (A, A′) or `Gemfile.next` (B), inside `Bundler.with_unbundled_env`.
* The twin loads only the standard library until the app's bundle is set up. `doubletrack
  run` and `capture` need nothing in the app's Gemfile; only running the generated
  reproduction specs does (ADR 0022).
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

Control A builds one template per snapshot kind the sessions use (`default`:
`db/schema.rb`, optionally `db/seeds.rb`; `fixtures`: schema plus the app's test fixtures,
ADR 0026), each with `VACUUM INTO`. Before each session, every twin copies it over its working database and
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

## Normalization, diff, noise, clustering **[built, M3]**

Normalizers are idempotent and property-tested: JSON keys sorted; HTML through Nokogiri
(ADR 0017) with tokens stripped; SQL canonicalized with literals moved out. The A vs A′
diff produces a noise mask keyed by route and concrete path (ADR 0019). A vs B
differences outside the mask are fingerprinted (channel + route + generalized path + op
+ value shape) and clustered across sessions. Severity rules live in one module
(ADR 0018). Design: `docs/design/diff.md`.

## Run and report **[built, M3]**

`doubletrack run` boots A, A′ and B in parallel, builds the snapshot templates, replays each
session on all three at once, and writes raw traces to `<out>/<run_id>/traces/`. It
then writes `findings.json`, `run.json` and `report/`. `doubletrack report` re-runs the
analysis from stored traces. The report is static HTML and CSS with one optional JS
file, and axe runs on it in CI.

## Data formats

All versioned and documented in `docs/formats/`: `sessions/*.jsonl` (session.md),
traces (trace.md), `<run_id>/findings.json` (findings.md), `<run_id>/run.json` (run.md),
`<run_id>/repros.json` (repros.md) and `doubletrack.baseline.yml` (baseline.md).

## Reproductions and baseline **[built, M4]**

Design: `docs/design/specgen.md`; ADRs 0022–0024.

```
doubletrack run:  replay → Results.compute (diff + baseline) ─┬─ new findings ─▶ Specgen::Generator
                                                             │   (A, A′, B still booted: truncate the session,
                                                             │    verify, greedily drop earlier requests)
                                                             ▼
                  Results.write: findings.json, run.json, repros.json, repro/{spec,test}/doubletrack/*, report

user's test process (bundle exec rspec / ruby -Itest):
  generated spec ─▶ Doubletrack::Repro.replay ─▶ one twin (role "repro") on $BUNDLE_GEMFILE
                                                 same twin/main.rb, overlay, clock, recorder
                 ◀─ normalized traces ◀──────────┘   assert the old value at the finding's path
```

`Repro.lookup` and `Repro.reproduces?` are shared by the run's verification and by the
generated specs, so "verified in the run" and "the spec passes on the current Rails"
are the same check. The baseline is read by both `run` and `report`. Accepted findings
stay in the results, but don't count toward the verdict or the exit code.

## Capture **[built, M5]**

Design: `docs/design/capture.md`; ADRs 0025–0027.

```
doubletrack capture APP
  ruby bin/rails test   (RUBYOPT=-r capture/boot.rb, BUNDLE_GEMFILE=current, DOUBLETRACK_CAPTURE_DIR=tmp)
    boot: bundler/setup → ActiveSupport lazy hooks
    Probe::SessionHook prepended to ActionDispatch::Integration::Session#process
      → one JSON line per request, per process (parallel workers OK)
  Capture::Assembler (pure): group by test → convert → redact → dedupe → sessions
  → doubletrack/sessions/captured.jsonl   (snapshot: "fixtures", test_status per request)

doubletrack run: one template per snapshot kind in use (default, fixtures), and capture
fidelity = replayed status on control A vs. test_status
```
