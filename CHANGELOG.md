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

### Changed
- Protocol schema_version 3: `prepare_snapshot` implemented; `hello` reports routes and the session cookie name; traces are trace_version 2.
- Twins no longer load `db/schema.rb` at boot; their database is empty until a snapshot is restored.
- Protocol schema_version 2: `run_session` returns `traces` and accepts `http_stubs`.
- Twins use a fresh `:memory_store` cache and `show_exceptions = :rescuable`.
