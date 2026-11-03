# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Gem skeleton and `doubletrack` CLI (`help`, `version`; other commands report the milestone that delivers them).
- Coordinator ↔ twin protocol (NDJSON on fds 3/4, schema_version 1) and twin process management with boot/request timeouts and crash detection.
- `bin/doubletrack-spike` (M0): boots an app on its current and next Rails versions and prints one response from each.
