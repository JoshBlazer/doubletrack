# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Gem skeleton and `doubletrack` CLI (`help`, `version`; other commands report the milestone that delivers them).
- Coordinator ↔ twin protocol (NDJSON on fds 3/4, schema_version 1) and twin process management with boot/request timeouts and crash detection.
- `bin/doubletrack-spike` (M0): boots an app on its current and next Rails versions and prints one response from each, with side-effect counts.
- Side-effect recorder (M1): every replayed request yields a trace with the response, SQL writes, enqueued jobs, delivered mail, cache writes/deletes, and outbound HTTP calls.
- Outbound `Net::HTTP` calls inside twins are answered from stubs or blocked with a synthetic 503; no socket is opened.

- Session replay (M2): sessions files (`sessions/*.jsonl`); per-session SQLite snapshot restore (`VACUUM INTO` template); time frozen per request at `started_at + offset_ms`; `rand` seeded per session; cookies carried across requests.
- Enqueued jobs are performed inline after each request, and their side effects recorded under `performed_jobs` (on by default; `perform_jobs: false` to disable).
- Traces record the route hit, the decoded session, and deprecation warnings.
- `Doubletrack::Normalize::Trace`: removes volatile values (request ids, runtimes, session ids, CSRF tokens, session-cookie ciphertext, backtraces).

- `doubletrack run [APP]`: replays every session on control A, control A′ and candidate B, then writes raw traces, `findings.json`, `run.json` and a static HTML report. Exit 0 means no findings, 1 means findings, 2 means error. `--seed` reproduces a run.
- `doubletrack report RESULTS_DIR`: regenerates findings and the report from stored traces.
- Normalizers for JSON (sorted keys), HTML (Nokogiri; attribute order, whitespace, CSRF tokens and nonces) and SQL (canonical text with literals moved out).
- Three-way noise mask, fingerprinting, clustering and severity (data-changing, user-visible, cosmetic). Cache writes count as data-changing.
- `doubletrack.yml` (optional): Gemfiles, sessions directory, seeds, `perform_jobs`, ignored columns and headers, timeouts.
- `make eval`: precision and recall on planted fixtures, with results in `eval/results/`.

- Reproduction specs (M4): `doubletrack run` builds one per new finding, checks it on the live twins (passes on the current Rails, fails on the next), drops earlier requests it doesn't need, and writes it as RSpec or Minitest (`repro_framework: auto|rspec|minitest`) under `results/<run_id>/repro/`, with a copy of the database snapshot. The report shows the spec, its verification and the commands to run it.
- `Doubletrack::Repro.replay`: the helper generated specs call. Add `gem "doubletrack", require: false, group: :test` to run them.
- `doubletrack accept ID --reason TEXT`: records a finding in `doubletrack.baseline.yml` (committed to the app). Later runs and reports mark it accepted; counts, the verdict and the exit code use new findings only. Stale entries are reported.
- `doubletrack run --baseline FILE --repro-framework NAME`; `doubletrack.yml` keys `baseline` and `repro_framework`.

- `doubletrack capture [APP] [--out FILE] [--command "SCRIPT ARGS"] [--gemfile FILE]` (M5): runs the app's tests on the current Rails with a probe on `ActionDispatch::Integration::Session#process`, and writes one session per request-making test to `doubletrack/sessions/captured.jsonl`. Requests that can't be replayed skip their test, with a reason; identical sessions are written once; values of secret-looking environment variables are redacted.
- Sessions can use `"snapshot": "fixtures"` (schema plus the app's test fixtures) and carry `test_status`; `doubletrack run` builds one template per snapshot kind and reports capture fidelity (replayed status vs. the test's) in the CLI, `run.json` and the report's coverage page.
- `doubletrack/http_stubs.json` (config key `http_stubs`): HTTP stubs added to captured sessions.

### Changed
- `run.json`: `snapshot` became `snapshots` (one per kind). `repros.json`: each repro names its own `snapshot`.
- `findings.json` occurrences carry `segments` and `op`; `run.json` gains `baseline`, `counts.accepted` and `timings.repro_s`. CLI output says "N new" and lists accepted counts.
- Twins render production error pages (`consider_all_requests_local = false`) instead of Rails' debug page.
- First runtime dependency: `nokogiri` (HTML normalization, coordinator only).
- Protocol schema_version 3: `prepare_snapshot` implemented; `hello` reports routes and the session cookie name; traces are trace_version 2.
- Twins no longer load `db/schema.rb` at boot; their database is empty until a snapshot is restored.
- Protocol schema_version 2: `run_session` returns `traces` and accepts `http_stubs`.
- Twins use a fresh `:memory_store` cache and `show_exceptions = :rescuable`.
