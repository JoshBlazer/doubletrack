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
    "control_a": {"rails_version": "8.0.5.1", "rails_revision": null, "ruby_version": "3.4.12", "bundle_gemfile": ".../Gemfile", "boot_ms": 2500.1,
                  "database": {"adapter": "sqlite3", "name": ".../work/control_a.sqlite3"}},
    "control_a_prime": {"...": "..."},
    "candidate_b": {"rails_version": "8.1.4", "...": "..."}
  },
  "routes": [{"verb": "GET", "path": "/orders(.:format)", "name": "orders", "controller": "orders", "action": "index"}],
  "dependency_changes": [
    {"name": "json", "from": "2.9.1", "to": "3.1.0", "from_path": "/gems/json-2.9.1", "to_path": "/gems/json-3.1.0", "git": null},
    {"name": "rails", "from": "8.2.0.alpha (e3d5c569d2)", "to": "8.2.0.alpha (8b06b0eb98)",
     "from_path": "/bundle/gems/rails-e3d5c569d217", "to_path": "/bundle/gems/rails-8b06b0eb9831",
     "git": {"cache": "/bundle/cache/bundler/git/rails-fcf0…", "from": "e3d5c569d2…", "to": "8b06b0eb98…", "remote": "https://github.com/rails/rails.git"}}
  ],
  "snapshots": {"default": {"bytes": 32768, "sha256": "…", "tables": {"orders": 0, "users": 0}},
                "fixtures": {"bytes": 40960, "sha256": "…", "tables": {"orders": 1, "users": 1}}},
  "capture_fidelity": {"requests": 13, "matched": 12, "mismatches": [
    {"session_id": "OrdersFlowTest-test_show…", "request_index": 1, "request": "GET /orders/1032760124.json?currency=EUR",
     "test_status": 200, "replay_status": "raised"}]},
  "sessions": [{"id": "checkout", "requests": 6, "findings": 2}],
  "timings": {"boot_s": 2.9, "snapshot_s": 0.2, "replay_s": 6.1, "analysis_s": 0.3, "attribution_s": 1.4, "repro_s": 1.2, "report_s": 0.1},
  "coverage": {
    "routes_total": 8, "routes_hit": 6, "ratio": 0.75,
    "routes": [{"verb": "GET", "path": "/orders(.:format)", "controller": "orders", "action": "index", "hits": 3, "hit": true}]
  },
  "noise": {
    "a_vs_a_prime_differences": 27,
    "a_vs_b_differences": 31,
    "suppressed": 27,
    "masked_paths": {"GET /orders(.:format)": ["response.body.json.request_token"]}
  },
  "counts": {"findings": 2, "changes": 2, "data-changing": 1, "user-visible": 1, "cosmetic": 0, "accepted": 1},
  "baseline": {"path": "/app/doubletrack.baseline.yml", "exists": true, "accepted": 1, "stale": []},
  "verdict": "not_ready"
}
```

`rails_revision` is the git revision of the loaded Rails when the bundle takes Rails from git (an app that tracks Rails main), and `null` for a released gem. Two twins on `8.2.0.alpha` at different revisions are different Rails versions; the report names them `8.2.0.alpha (1a02651ac3)`.

`dependency_changes` (M7, ADR 0032) lists the gems whose version or revision differs between
control A's and candidate B's loaded gems (`hello` `gems`). Gems from one git checkout
(rails, actionpack, …) are one entry named after the repository, with Bundler's clone in
`git.cache`. A gem the current bundle hadn't loaded at boot has `from: null`. Likely causes
(`findings.json` `changes[].causes`) are searched in these paths.

`routes` is candidate B's route table from `hello`. It's kept so that
`doubletrack report` can recompute coverage without twins. `twins.*.session_cookie` is
kept for the same reason.

`snapshots` has one entry per snapshot kind the sessions use (M5, ADR 0026; M2–M4
runs wrote a single `snapshot`). `capture_fidelity` is present only when sessions carry
`test_status` (captured sessions). It counts the requests whose replay on control A got
the status their test saw, and lists up to 50 mismatches (ADR 0027).

`counts` covers **new** findings only (not in the baseline); `counts.changes` is the number of
changes that group them (ADR 0031); `counts.accepted` is the
number of findings the baseline accepted. `baseline.stale` lists accepted ids not seen in
this run (M4, ADR 0024). `verdict` is `ready` (no new data-changing or user-visible
findings) or `not_ready`. `seed`
plus the same sessions and app reproduces the run (`doubletrack run --seed 1234`).
