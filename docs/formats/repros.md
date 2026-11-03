# Format: reproductions (`results/<run_id>/repros.json`, repros_version 1)

Written by `doubletrack run`. `doubletrack report` re-renders the spec files from it.
Design: `docs/design/specgen.md`, ADRs 0022–0023.

```json
{
  "repros_version": 1,
  "run_id": "20261103T072146Z-42",
  "framework": "minitest",
  "repros": [
    {
      "finding_id": "f-bb3068808cf1",
      "title": "GET /orders/:id(.:format): exception.message changed",
      "severity": "user-visible",
      "session_id": "unstubbed-rate",
      "snapshot": "snapshots/1a2b3c4d5e6f.sqlite3",
      "seed": 1234567890,
      "started_at": "2026-01-01T00:00:00Z",
      "perform_jobs": true,
      "http_stubs": [],
      "requests": [{"method": "GET", "path": "/orders/1/rate", "params": {}, "headers": {}, "offset_ms": 0}],
      "kept_request_indexes": [1],
      "requests_before": 2,
      "segments": ["exception", "message"],
      "op": "changed",
      "expected": "unexpected token at ''",
      "expected_absent": false,
      "normalize": {"ignored_headers": [], "ignored_columns": []},
      "status": "reproduced",
      "observed": {"control_a": {"value": "unexpected token at ''"},
                   "control_a_prime": {"value": "unexpected token at ''"},
                   "candidate_b": {"value": "unexpected end of input at line 1 column 1"}},
      "file": "repro/test/doubletrack/f-bb3068808cf1_test.rb"
    }
  ]
}
```

| Field | Notes |
|---|---|
| `framework` | `rspec` or `minitest`: the resolved `repro_framework` |
| `snapshot` | Per repro (M5): the copy of the template for the session's snapshot kind, relative to the spec directory (`repro/spec/doubletrack/` or `repro/test/doubletrack/`). M4 files had one top-level `snapshot`, which is still read as the fallback. |
| `seed` | The session's seed in the run (`Session.seed_for(run_seed, session_id)`) |
| `requests` | Minimized. The last one is the finding's request. |
| `kept_request_indexes` | Indexes into the original session |
| `requests_before` | Length of the truncated session before minimization |
| `segments` | Path into the last request's normalized trace: strings are keys, integers are array indexes |
| `expected_absent` | `true` for `added` differences. The spec then asserts `Doubletrack::Repro::ABSENT`. |
| `status` | `reproduced` (A and A′ give `expected`, B doesn't), `not_reproduced`, or `error` (a twin failed while replaying; only `finding_id`, `title`, `severity` and `error` are set, and no file is written) |
| `observed` | Per role, `{"value": …}` or `{"absent": true}` for a missing path, as seen in the last verification replay |
