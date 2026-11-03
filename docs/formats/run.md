# Format: run metadata (`results/<run_id>/run.json`, run_version 1)

Written by `doubletrack run`. Everything needed to understand or reproduce a run.

```json
{
  "run_version": 1,
  "run_id": "20261103T070000Z-1234",
  "seed": 1234,
  "doubletrack_version": "0.0.1",
  "app": {"name": "Shop", "root": "/path/to/app"},
  "started_at": "2026-11-03T07:00:00Z",
  "finished_at": "2026-11-03T07:00:21Z",
  "options": {"perform_jobs": true, "seeds": false, "ignored_columns": [], "ignored_headers": []},
  "twins": {
    "control_a": {"rails_version": "8.0.5.1", "ruby_version": "3.4.12", "bundle_gemfile": ".../Gemfile", "boot_ms": 2500.1},
    "control_a_prime": {"...": "..."},
    "candidate_b": {"rails_version": "8.1.4", "...": "..."}
  },
  "snapshot": {"bytes": 32768, "sha256": "…", "tables": {"orders": 0, "users": 0}},
  "sessions": [{"id": "checkout", "requests": 6, "findings": 2}],
  "timings": {"boot_s": 2.9, "snapshot_s": 0.2, "replay_s": 6.1, "analysis_s": 0.3, "report_s": 0.1},
  "coverage": {
    "routes_total": 8, "routes_hit": 6, "ratio": 0.75,
    "routes": [{"verb": "GET", "path": "/orders(.:format)", "controller": "orders", "action": "index", "hits": 3}]
  },
  "noise": {
    "a_vs_a_prime_differences": 27,
    "a_vs_b_differences": 31,
    "suppressed": 27,
    "masked_paths": {"GET /orders(.:format)": ["response.body.json.request_token"]}
  },
  "counts": {"findings": 2, "data-changing": 1, "user-visible": 1, "cosmetic": 0},
  "verdict": "not_ready"
}
```

`verdict` is `ready` (no data-changing or user-visible findings) or `not_ready`. `seed`
plus the same sessions and app reproduces the run (`doubletrack run --seed 1234`).
