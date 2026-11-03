# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Gem skeleton and `doubletrack` CLI (`help`, `version`; other commands report the milestone that delivers them).
- Coordinator ↔ twin protocol (NDJSON on fds 3/4, schema_version 1) and twin process management with boot/request timeouts and crash detection.
- `bin/doubletrack-spike` (M0): boots an app on its current and next Rails versions and prints one response from each, with side-effect counts.
- Side-effect recorder (M1): every replayed request yields a trace with the response, SQL writes, enqueued jobs, delivered mail, cache writes/deletes, and outbound HTTP calls.
- Outbound `Net::HTTP` calls inside twins are answered from stubs or blocked with a synthetic 503; no socket is opened.

### Changed
- Protocol schema_version 2: `run_session` returns `traces` and accepts `http_stubs`.
- Twins use a fresh `:memory_store` cache and `show_exceptions = :rescuable`.
