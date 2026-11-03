# Doubletrack

**Upgrade Rails with proof, not hope.**

Doubletrack replays real or synthesized traffic against your Rails app running on the
**current** and the **next** Rails version side by side. It reports every behavioral
difference (HTTP responses, database writes, enqueued jobs, emails, cache writes,
outbound HTTP calls), each backed by a minimal reproduction spec.

> **Status: pre-alpha. M0–M2 done; M3 (diff and report) next.** Doubletrack can't
> compare versions or report differences yet. What works today:
> * booting one app on two Rails versions as separate processes;
> * replaying multi-request sessions deterministically, from a database snapshot, with a
>   frozen clock and seeded randomness;
> * recording each request's response and side effects (SQL writes, jobs, mail, cache,
>   outbound HTTP), including what enqueued jobs do when performed.
>
> The table below is the source of truth.

## 30-second demo (M0)

```console
$ bin/doubletrack-spike fixtures/apps/shop --path /orders
Doubletrack spike: Shop (/home/meli/doubletrack/fixtures/apps/shop)
Twins booted in parallel in 4.4s
  control_a    Ruby 3.4.12  Rails 8.0.5.1  env doubletrack pid 55021   boot   4079 ms  Gemfile
  candidate_b  Ruby 3.4.12  Rails 8.1.4    env doubletrack pid 55022   boot   4072 ms  Gemfile.next

GET /orders
  control_a    Rails 8.0.5.1  -> 200  text/html; charset=utf-8  609 bytes  405.7 ms
    | <h1>Orders</h1> ... <p>No orders yet.</p>
  candidate_b  Rails 8.1.4    -> 200  text/html; charset=utf-8  609 bytes  340.7 ms
    | <h1>Orders</h1> ... <p>No orders yet.</p>
```

One app checkout, two Rails versions, two processes, one request each. (Body lines
abbreviated here; full output in [`docs/walkthroughs/m0.md`](docs/walkthroughs/m0.md).
Timings: a single run on an i7-7600U laptop under WSL2, not a benchmark.)

## Status

Every row names the command or test that proves it. A row is ✅ only if that command
passes; "CI" marks whether it has also been seen green in GitHub Actions.

| Capability | Milestone | Status | Proof | CI |
|---|---|---|---|---|
| Gem skeleton, CLI `help`/`version`, exit codes | M0 | ✅ | `bundle exec rspec spec/doubletrack/cli_spec.rb` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| Protocol: envelope, NDJSON framing, timeouts, binary bodies | M0 | ✅ | `bundle exec rspec spec/doubletrack/protocol` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| Twin lifecycle: clean env, stdout isolation, crash/hang detection | M0 | ✅ | `bundle exec rspec spec/doubletrack/coordinator` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| `shop` fixture dual-boots Rails 8.0 / 8.1 | M0 | ✅ | `cd fixtures/apps/shop && bin/rails test && BUNDLE_GEMFILE=Gemfile.next bin/rails test` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| **Twins talk: one request to each version** | **M0** | ✅ | `bin/doubletrack-spike fixtures/apps/shop` and `bundle exec rake spec:integration` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| Lint (standardrb) | M0 | ✅ | `bundle exec rake standard` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| Gem builds | M0 | ✅ | `gem build doubletrack.gemspec` | ✅ [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| Outbound HTTP blocked and recorded (`Net::HTTP`), no socket opened | M1 | ✅ | `bundle exec rspec spec/doubletrack/recorder` | ✅ [run 41556339580](https://github.com/JoshBlazer/doubletrack/actions/runs/41556339580) |
| **Side-effect recorder: traces with response, SQL writes, jobs, mail, cache, HTTP** | **M1** | ✅ | `bundle exec rake spec:integration` (`spec/integration/recorder_spec.rb`, both Rails versions) | ✅ [run 41556339580](https://github.com/JoshBlazer/doubletrack/actions/runs/41556339580) |
| Frozen clock, session loader, trace normalizer (property-tested) | M2 | ✅ | `bundle exec rspec spec/doubletrack/twin spec/doubletrack/session_spec.rb spec/doubletrack/normalize` | ✅ [run 41592499206](https://github.com/JoshBlazer/doubletrack/actions/runs/41592499206) |
| **Session replay: snapshots, frozen time, seeded rand, cookies, jobs performed inline; same session twice → identical normalized traces** | **M2** | ✅ | `bundle exec rake spec:integration` (`spec/integration/replay_spec.rb`, both Rails versions) | ✅ [run 41592499206](https://github.com/JoshBlazer/doubletrack/actions/runs/41592499206) |
| Diff, noise cancellation, clustering, static report | M3 | not started | – | – |
| Precision/recall eval (`make eval`) | M3 | not started | – | – |
| Reproduction specs and baseline (`accept`) | M4 | not started | – | – |
| Test-derived capture (`capture`) | M5 | not started | – | – |
| Real-world demo | M6 | not started | – | – |

CI runs lint, unit specs on Ruby 3.2/3.3/3.4/4.0, the integration specs (M0, M1 and M2 exit checks) on Ruby 3.4, and a gem build.

## Quick start (contributors)

Requirements: Linux or macOS (Windows: use WSL, see ADR 0003), Ruby ≥ 3.2, SQLite.

```sh
bundle install
bundle exec rake               # lint + unit specs
make fixtures                  # install the shop fixture's two bundles (Rails 8.0 and 8.1)
bin/doubletrack-spike fixtures/apps/shop --path /orders
bundle exec rake spec:integration
```

## How it works

Each Rails version runs in its own process ("twin") with its own `BUNDLE_GEMFILE`, using
the `next_rails` dual-boot convention. A coordinator talks to the twins over dedicated
pipes (fds 3/4) with newline-delimited JSON, so nothing the app prints can corrupt the
protocol. Two controls on the old version (A, A′) and a candidate on the new version (B)
let Doubletrack separate real upgrade differences from noise. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[`docs/design/protocol.md`](docs/design/protocol.md).

## Limitations (read these)

What Doubletrack can't do, today and by design:

* **It can't find differences yet.** Diffing and the report (M3) aren't built. Today it
  replays sessions on both versions and records what each request does, but doesn't
  compare the results.
* **Outbound HTTP:** only clients built on `Net::HTTP` are intercepted (ADR 0012).
  `httpx`, `curb`/`typhoeus` and raw sockets are **not** intercepted yet. Unstubbed
  `Net::HTTP` calls get a synthetic 503.
* **Jobs are performed inline**, right after the request that enqueued them (ADR 0014),
  at most 25 per request. That ordering differs from a real queue. Turn it off with
  `perform_jobs: false`.
* **Determinism has limits** (ADR 0015). `SecureRandom` isn't controlled, and time read
  by SQLite itself (`CURRENT_TIMESTAMP`) isn't frozen. In-memory Ruby state that survives
  between sessions (memoized class variables) isn't reset; only the database, cache, mail
  and job queues are.
* **Cache:** twins use a fresh `:memory_store` (ADR 0011), whatever store your app
  configures.
* **SQLite only** in the MVP, for observed apps too. Postgres/MySQL apps aren't supported
  yet.
* **No native Windows.** Linux and macOS only; Windows via WSL.
* **One Ruby for both twins.** Both versions run under the coordinator's Ruby; per-app
  `.ruby-version` support is future work.
* **No browser behavior.** JavaScript and system tests with real browsers are out of
  scope.
* **Rails 7.1 → 8.1, adjacent minor versions only** (ADR 0008). Only the 8.0 → 8.1 pair
  has a fixture so far.
* The twin runs in a `doubletrack` Rails environment built from your `test` environment
  (ADR 0009). Code that branches on `Rails.env.test?` will see `false`.
* Snapshots are built from `db/schema.rb` (optionally plus `db/seeds.rb`).
  `structure.sql` apps and multiple databases aren't supported yet. Each session costs a
  file copy of the template.

## Privacy

No telemetry, no accounts, no network calls. Reports are static files. Nothing leaves your
machine.

## AI assistance

Doubletrack is built with an AI coding assistant (Claude Code) and reviewed by the
author, JoshBlazer, who owns every commit. Modules that started from a design note and
tests written before the implementation:

| Module | Design note | Tests first? |
|---|---|---|
| Protocol (`lib/doubletrack/protocol/`) | [`docs/design/protocol.md`](docs/design/protocol.md) | Design note first; specs written alongside the code in the same session (not strictly before) |
| Recorder (`lib/doubletrack/recorder/`) | [`docs/design/recorder.md`](docs/design/recorder.md) | Design note and the integration exit-check spec first (run red: 12/12 failing); interceptor/converter unit specs written alongside the code |
| Replay: snapshots, clock, sessions, normalizer (`lib/doubletrack/twin/`, `session.rb`, `normalize/`) | [`docs/design/replay.md`](docs/design/replay.md) | Yes: design note, then the exit-check and unit specs committed red before the implementation |

The design notes in this repository were drafted with the assistant from the author's
written brief and reviewed by the author.

## License

MIT. See [LICENSE](LICENSE).
