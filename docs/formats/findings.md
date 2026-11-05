# Format: findings (`results/<run_id>/findings.json`, findings_version 2)

Written by `doubletrack run` and `doubletrack report`. Design: `docs/design/diff.md`.

```json
{
  "findings_version": 2,
  "run_id": "20261103T070000Z-1234",
  "changes": [
    {
      "id": "c-902afdb15c9d",
      "severity": "cosmetic",
      "kind": "response",
      "path": "response.headers.vary",
      "op": "changed",
      "summary": "adds X-Requested-With",
      "delta": [{"added": ["X-Requested-With"], "removed": []}],
      "added_runs": [],
      "findings": ["f-07b7ddf757f4", "f-0902c2920971"],
      "routes": ["GET /account/bots(.:format)", "GET /rooms/:id(.:format)"],
      "sessions": 3,
      "occurrences_total": 4,
      "accepted": false,
      "causes": [
        {"dependency": "rails", "evidence": "commit", "ref": "e38dd281d3",
         "text": "Vary rendered responses by negotiation headers", "needle": "X-Requested-With",
         "url": "https://github.com/rails/rails/commit/e38dd281d340d28bda39877ee83665f092091de2"}
      ]
    }
  ],
  "findings": [
    {
      "id": "f-3a9c0e1b7d22",
      "severity": "data-changing",
      "kind": "sql_writes",
      "route": "POST /orders(.:format)",
      "path": "sql_writes[*].binds.name",
      "op": "changed",
      "title": "POST /orders(.:format): sql_writes[*].binds.name changed",
      "change_id": "c-5b0e2f6a9c13",
      "sessions": 3,
      "occurrences_total": 4,
      "occurrences": [
        {"session_id": "checkout", "request_index": 0, "path": "sql_writes[0].binds.name",
         "segments": ["sql_writes", 0, "binds", "name"], "op": "changed",
         "a": "Ada  Lovelace", "b": "Ada Lovelace",
         "traces": {"control_a": "traces/checkout/control_a.json", "candidate_b": "traces/checkout/candidate_b.json"}}
      ]
    }
  ]
}
```

| Field | Notes |
|---|---|
| `id` | Fingerprint (ADR 0019): stable across runs, used by `doubletrack accept` and the baseline (ADR 0024). |
| `accepted` | Present only for findings listed in the baseline: `{"reason", "author", "accepted_at"}`. Accepted findings don't count toward `run.json` counts, the verdict or the exit code. |
| `severity` | `data-changing`, `user-visible`, or `cosmetic` (ADR 0018). |
| `kind` | Channel: `response`, `exception`, `session`, `sql_writes`, `jobs`, `mail`, `cache`, `http`, or `performed_jobs.<channel>`. |
| `path` | Generalized path (`[*]` for array indices). Each occurrence has the concrete one. |
| `sessions` | Number of distinct sessions with this finding. |
| `occurrences` | At most 20, in run order. `a` is the normalized control A value and `b` the candidate B value (`null` for added or removed). `segments` is the concrete path as an array (integers are array indexes) and `op` the leaf-level change (`added`, `removed`, `changed`). Both were added in M4 for reproductions. |

Findings are sorted by severity (data-changing first), then route, then path.

### Changes (M7, ADR 0031, 0032)

| Field | Notes |
|---|---|
| `id` | `c-` + 12 hex of SHA-256 over `[kind, path, op, delta]`: stable across runs. `doubletrack accept c-…` accepts every finding of the change. |
| `delta` | The sorted set of the change's occurrence deltas: `{"added", "removed"}` tokens for strings, or `{"from", "to"}` shapes (values at enumerated leaves, types elsewhere). Findings with the same `kind`, `path`, `op` and `delta` are one change. |
| `summary` | Human text from the delta: `adds X`, `removes Y`, `200 → 500`, the quoted values when many tokens change, or `changed` for HTML bodies. |
| `added_runs` | Runs of 2+ consecutive added words in the first occurrence, searched first for causes. |
| `severity` | The most severe of its findings. |
| `accepted` | `true` when every finding of the change is accepted. |
| `causes` | At most 3 likely causes, best first. `evidence` is `commit` (a commit between the two git revisions whose diff adds or removes `needle`, with `url` for GitHub remotes), `changelog` (a new `CHANGELOG.md` line mentioning it; `ref` is the file) or `source` (a file containing it on one side of the upgrade only). Text matches, not proof. |
| `causes_searched` | Present and `false` when the search's time budget ran out before this change. |

Changes are sorted by severity, then by number of findings (largest first). Each finding's
`change_id` points at its change.
