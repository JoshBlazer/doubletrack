# Doubletrack

**Upgrade Rails with proof, not hope.**

Doubletrack replays traffic (sessions captured from your tests, or written by hand)
against your Rails app running on the **current** and the **next** Rails version side by
side. It reports every behavioral difference it observes (HTTP responses, database
writes, enqueued jobs, emails, cache writes, outbound HTTP calls), and writes a
reproduction spec for each new finding, checked during the run.

> **Status: pre-alpha. M0–M6 done.** What works
> today:
> * `doubletrack capture` turns your integration tests and request specs into replay
>   sessions, and measures whether each replays the way its test ran;
> * `doubletrack run` replays those (or hand-written) sessions on your current Rails
>   (twice) and your next Rails;
> * it compares responses, SQL writes, jobs (including what they do when performed),
>   mail, cache writes and outbound HTTP;
> * it filters noise, groups differences into findings with a severity, and writes a
>   static report;
> * every new finding gets a reproduction spec (RSpec or Minitest), checked during the
>   run: it passes on the current Rails and fails on the next;
> * `doubletrack accept` records expected differences in a committed baseline, and
>   later runs report only new findings.
>
> On a real app: [once-campfire PR #423](docs/walkthroughs/m6.md) (Rails main
> `e3d5c569` → `8b06b0eb`), 553 captured requests, 22 verified findings, the same on
> three seeds ([published report](https://joshblazer.github.io/doubletrack/campfire-pr423/)). The table below is the source of truth.

## 30-second demo (M4)

From a checkout of this repository, after `bundle install` and `make fixtures`:

```console
$ bundle exec exe/doubletrack run fixtures/apps/shop --seed 42 --baseline tmp/demo-baseline.yml
Booting control A, control A′ (Gemfile) and candidate B (Gemfile.next)...
  [########################] 5/5 sessions  done
Verifying reproductions for 1 new finding...
Doubletrack 20261103T203131Z-42: Shop, Rails 8.0.5.1 → 8.1.4
  5 sessions, 14 requests replayed on control A, control A′ and candidate B
  Findings: 1 new  (data-changing 0, user-visible 1, cosmetic 0)
    [user-visible] GET /orders/:id(.:format): exception.message changed  (1 session, f-bb3068808cf1)
  Reproductions: 1 verified, 0 not verified (minitest, .../repro/test/doubletrack)
  Noise filtered: 0 (0 A/A′ differences observed)
  Route coverage: 7 of 8 routes (88%)
  Verdict: Not ready to ship
  Report: .../tmp/doubletrack/20261103T203131Z-42/report/index.html

$ REPRO=$PWD/fixtures/apps/shop/tmp/doubletrack/20261103T203131Z-42/repro/test/doubletrack/f-bb3068808cf1_test.rb
$ (cd fixtures/apps/shop && bundle exec ruby -Itest $REPRO)
1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
$ (cd fixtures/apps/shop && BUNDLE_GEMFILE=Gemfile.next bundle exec ruby -Itest $REPRO)
--- expected
+++ actual
@@ -1 +1 @@
-"unexpected token at ''"
+"unexpected end of input at line 1 column 1"
1 runs, 1 assertions, 1 failures, 0 errors, 0 skips

$ bundle exec exe/doubletrack accept f-bb3068808cf1 --reason "We never show JSON parser messages to users" \
    --baseline tmp/demo-baseline.yml fixtures/apps/shop
Accepted f-bb3068808cf1 in .../tmp/demo-baseline.yml
$ bundle exec exe/doubletrack run fixtures/apps/shop --seed 42 --baseline tmp/demo-baseline.yml
  Findings: 0 new  (data-changing 0, user-visible 0, cosmetic 0), 1 accepted in demo-baseline.yml
  Verdict: Ready to ship                                                 # exit 0
```

(In your own app you'd leave out `--baseline`: the baseline then lives in the app root
as `doubletrack.baseline.yml`, committed with your code. The demo keeps it out of the
fixture.)

Sessions can also come from the app's own tests (M5):

```console
$ bundle exec exe/doubletrack capture fixtures/apps/shop --out tmp/captured/captured.jsonl
Running `bin/rails test` on Gemfile with the capture probe...
Captured 7 sessions (13 requests) from 7 tests that made requests
  tests: passed
  Written: .../tmp/captured/captured.jsonl
$ bundle exec exe/doubletrack run fixtures/apps/shop --sessions tmp/captured
  ...
  Capture fidelity: 13/13 requests replayed with the status their test saw
```

(`make capture-shop` does the same. Without `--out`, capture writes
`doubletrack/sessions/captured.jsonl` in the app, next to its hand-written sessions.)

That finding is real. When the shop parses an empty response body, Rails 8.0's bundle
raises `unexpected token at ''`, and Rails 8.1's bundle, which pins `json 3.1.0`, raises
`unexpected end of input at line 1 column 1`. Exit code 1 means new differences were
found (`run` and `report`; 2 means Doubletrack itself failed).
The reproduction replays the 2 requests it needs (create an order, then fetch its rate)
on a copy of the run's database snapshot, in a separate process of the app on whichever
Rails `bundle exec` selects. The report is static HTML.

On the planted eval fixtures, Doubletrack catches 9 of 9 planted changes with no false
positives and finds nothing in the clean app. All 13 findings get a reproduction that,
run for real under Minitest, passes on Rails 8.0 and fails on 8.1 (`make eval`; this is
a small corpus, see [`eval/README.md`](eval/README.md)). Full output is in
[`docs/walkthroughs/m4.md`](docs/walkthroughs/m4.md) and
[`docs/walkthroughs/m3.md`](docs/walkthroughs/m3.md). Timings come from one run on an
i7-7600U laptop under WSL2, not a benchmark.

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
| Normalizers (JSON, HTML, SQL), structural diff, noise mask, severity, fingerprint, clustering (property-tested) | M3 | ✅ | `bundle exec rspec spec/doubletrack/normalize spec/doubletrack/diff` | ✅ [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| Static report: overview, findings, detail, coverage, noise; offline, no-JS | M3 | ✅ | `bundle exec rspec spec/doubletrack/report` | ✅ [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| Report accessibility: axe (WCAG 2.1 A/AA rules), 0 violations on every page | M3 | ✅ (CI only) | `report-a11y` CI job | ✅ [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| **`doubletrack run` on shop: three-way replay → findings + report** | **M3** | ✅ | `make run-shop`, `spec/integration/run_spec.rb` | ✅ [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| **Precision/recall eval: planted 9/9, precision 1.00, clean 0 findings** | **M3** | ✅ | `make eval`, `spec/integration/eval_spec.rb` | ✅ [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| Repro helper, spec writer (RSpec/Minitest), minimizer, baseline file | M4 | ✅ | `bundle exec rspec spec/doubletrack/repro_spec.rb spec/doubletrack/specgen spec/doubletrack/baseline_spec.rb spec/doubletrack/results_spec.rb` | ✅ [run 41714163293](https://github.com/JoshBlazer/doubletrack/actions/runs/41714163293) |
| **Generated spec passes on old and fails on new (RSpec and Minitest, run for real); `accept` suppresses the finding on the next run** | **M4** | ✅ | `bundle exec rake spec:integration` (`spec/integration/repro_spec.rb`) | ✅ [run 41714163293](https://github.com/JoshBlazer/doubletrack/actions/runs/41714163293) |
| **Eval: every planted finding's repro passes on 8.0 and fails on 8.1 (13/13)** | **M4** | ✅ | `make eval`, `spec/integration/eval_spec.rb` | ✅ [run 41714163293](https://github.com/JoshBlazer/doubletrack/actions/runs/41714163293) |
| Capture probe, record builder, assembler (grouping, redaction, dedupe), `fixtures` snapshot sessions | M5 | ✅ | `bundle exec rspec spec/doubletrack/capture spec/doubletrack/session_snapshot_spec.rb` | ✅ [run 41717869635](https://github.com/JoshBlazer/doubletrack/actions/runs/41717869635) |
| **`doubletrack capture` on shop: one session per request-making test; `run` replays them with capture fidelity 13/13** | **M5** | ✅ | `bundle exec rake spec:integration` (`spec/integration/capture_spec.rb`, capture on both Rails versions) | ✅ [run 41717869635](https://github.com/JoshBlazer/doubletrack/actions/runs/41717869635) |
| Hardening after a review of M0–M5: generated-spec escaping and strictness, exit codes, twin pipes and paths, capture grouping, config validation | post-M5 | ✅ | `bundle exec rake` and `bundle exec rake spec:integration` (each fix has a spec named after it) | ✅ [run 41733480715](https://github.com/JoshBlazer/doubletrack/actions/runs/41733480715) |
| Real-world run: once-campfire PR #423 captured (215 sessions, 553 requests) and replayed on Ruby 4.0.9 → 22 verified findings, 0 unverified, same ids on seeds 42/7/1234; all 22 generated tests pass on Campfire's current Rails and fail on the PR's | M6 | ✅ (local) | `doubletrack capture` + `doubletrack run --seed 42` on a once-campfire checkout ([walkthrough](docs/walkthroughs/m6.md) §2) | ✅ [run 42082544994](https://github.com/JoshBlazer/doubletrack/actions/runs/42082544994) (the Doubletrack fixes; the Campfire run itself is local) |
| Published report + maintainers contacted + upstream issues | M6 | ✅ | [report on Pages](https://joshblazer.github.io/doubletrack/campfire-pr423/) (`gh-pages` branch, local paths replaced with `/app`); [comment on #423](https://github.com/basecamp/once-campfire/pull/423#issuecomment-6667493665) | – |

CI runs lint, unit specs on Ruby 3.2/3.3/3.4/4.0, the integration specs (M0–M5 exit checks) on Ruby 3.4, `make eval`, axe on a generated report, and a gem build.

## Quick start (contributors)

Requirements: Linux or macOS (Windows: use WSL, see ADR 0003), Ruby ≥ 3.2, SQLite.

```sh
bundle install
bundle exec rake               # lint + unit specs
make fixtures                  # install the fixture apps' two bundles each (Rails 8.0 and 8.1)
bundle exec exe/doubletrack run fixtures/apps/shop   # replay, diff, report; exits 1: shop has one real finding
make eval                      # precision/recall on the planted fixtures
bundle exec rake spec:integration
```

To try it on your own app, you need:
* dual boot with the `next_rails` convention (`Gemfile` and `Gemfile.next`);
* SQLite with a `db/schema.rb`;
* sessions in `doubletrack/sessions/*.jsonl` ([format](docs/formats/session.md)). You
  can write them by hand, or run `bundle exec exe/doubletrack capture path/to/app` (from
  this repository) to derive them from
  your integration tests and request specs. Put canned responses for outbound HTTP in
  `doubletrack/http_stubs.json`.

Then, from this repository, run `bundle exec exe/doubletrack run path/to/app` (the gem
isn't on rubygems.org yet). An optional `doubletrack.yml` configures it
(see `lib/doubletrack/config.rb`). Results go to `path/to/app/tmp/doubletrack/`,
including the generated reproduction specs (`repro/`). Nothing is written to your app's
code. The one exception is `doubletrack accept`, which writes `doubletrack.baseline.yml`
in the app root when you ask it to.

To run the reproduction specs, add the gem to your app's test group (in the shared
`Gemfile`, so both bundles have it). Until it's released, point Bundler at the
repository:

```ruby
gem "doubletrack", github: "JoshBlazer/doubletrack", require: false, group: :test
# or, with a local checkout: gem "doubletrack", path: "../doubletrack", require: false, group: :test
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

* **Coverage comes from your sessions.** `doubletrack capture` covers what your
  integration tests and request specs exercise. It doesn't cover system tests
  (browser-driven), model tests, or requests made outside the integration session
  (ADR 0025). A report is only as strong as its route coverage, and the report shows
  it.
* **Captured sessions replay what the test sent, not what the test stubbed.** App-level
  stubs (for example swapping a client object), `sign_in` helpers that skip requests,
  and test-only setup don't carry over. Capture fidelity shows each request whose
  replay status differs from its test (ADR 0027). Outbound HTTP needs
  `doubletrack/http_stubs.json`.
* **Redaction is value-based.** Capture redacts the values of secret-looking
  environment variables. A secret that's hard-coded in a test, or absent from the
  capture environment, isn't caught.
* **Reproduction specs compare strictly.** A generated spec checks the old value with
  `eql` (RSpec) or `Doubletrack::Repro.same?` (Minitest), as strictly as the run
  verified it: `1` and `1.0` differ.
* **Reproduction specs replay through Doubletrack, not `rails_helper`** (ADR 0022). Each
  one boots a separate process of your app in the `doubletrack` environment, so it
  matches what the run saw. It isn't an idiomatic request spec, and turning it into one
  is up to you. The first repro in a test process pays one app boot (a few seconds).
* **Minimization is greedy.** It drops whole earlier requests one at a time (ADR 0023),
  not params or stubs, and the result isn't guaranteed minimal. Verifying repros adds
  replays to the run: on the planted app, 5.6 s against a 2.0 s replay.
* **Repro snapshots are binary SQLite files** built from your schema (and seeds, if
  enabled). Copying a repro into your repo means committing that file.
* **The baseline matches on the fingerprint** (ADR 0024). An accepted finding also
  covers later changes of the same kind at the same place. For example, a string that
  changes to a different value next time stays accepted. Values at enumerated leaves
  (status codes, job classes, queue names and so on) are part of the fingerprint, so a
  different status change is a new finding.
* **Small eval corpus.** "9/9, precision 1.00" is measured on one planted app with 9
  version-gated plants (ADR 0020). It isn't a general accuracy claim.
* **Diff granularity.** Array diffs are index-based, so one extra SQL write early in a
  request can shift later paths into several findings. All changes inside an HTML page
  become one finding per route. A framework change that affects every route gives one
  finding per route.
* **Noise masking can hide real changes** at a path that was also noisy between the two
  controls. Masked paths are always listed on the report's noise page.
* **Error pages:** twins render your production error pages
  (`consider_all_requests_local = false`, ADR 0021), not Rails' debug page.
* **Outbound HTTP:** only clients built on `Net::HTTP` are intercepted (ADR 0012).
  `httpx`, `curb`/`typhoeus` and raw sockets are **not** intercepted yet. Unstubbed
  `Net::HTTP` calls get a synthetic 503.
* **Jobs are performed inline**, right after the request that enqueued them (ADR 0014),
  at most 25 per request. That ordering differs from a real queue. Turn it off with
  `perform_jobs: false`.
* **Control A also builds the snapshot.** Loading the schema, seeds and fixtures runs in
  control A's process, so anything the app memoizes at class level while doing that
  exists in A but not in A′ or B. A difference between A and A′ caused by it would be
  treated as noise (masked), not reported.
* **Very large responses:** a response body over about 48 MB doesn't fit in one protocol
  frame. The run stops with an error naming the twin, instead of comparing it.
* **Captured requests lose their host.** `get "http://admin.example.com/x"` replays as
  `/x` on the default host, so subdomain-constrained routes don't match.
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
  `structure.sql` apps and multiple databases aren't supported yet. Each session restores
  the template in place through SQLite's backup API (ADR 0029).

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
| Diff, noise mask, clustering, severity, report, eval (`diff/`, `normalize/{json,html,sql}.rb`, `report/`, `eval/`) | [`docs/design/diff.md`](docs/design/diff.md) | Yes: design note, then all specs and both integration exit checks committed red; two later fixes (debug error pages, HTML clustering) also started from a failing spec |
| Reproduction specs and baseline (`specgen/`, `repro.rb`, `baseline.rb`) | [`docs/design/specgen.md`](docs/design/specgen.md) | Yes: design note and formats, then unit and integration specs committed red (`edcd8be`) |
| Test-derived capture (`capture/`, `capture.rb`) | [`docs/design/capture.md`](docs/design/capture.md) | Yes: design note and ADRs, then unit and integration specs committed red (`dcdc24d`) |
| Hardening after a review of M0–M5 (generated-spec escaping and strictness, exit codes, twin pipes, paths) | Findings of three independent review passes, listed in `docs/PROGRESS.md` | Yes: one failing spec per finding committed red first |

The design notes in this repository were drafted with the assistant from the author's
written brief and reviewed by the author.

## License

MIT. See [LICENSE](LICENSE).
