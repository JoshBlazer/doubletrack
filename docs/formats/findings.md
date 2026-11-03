# Format: findings (`results/<run_id>/findings.json`, findings_version 1)

Written by `doubletrack run` and `doubletrack report`. Design: `docs/design/diff.md`.

```json
{
  "findings_version": 1,
  "run_id": "20261103T070000Z-1234",
  "findings": [
    {
      "id": "f-3a9c0e1b7d22",
      "severity": "data-changing",
      "kind": "sql_writes",
      "route": "POST /orders(.:format)",
      "path": "sql_writes[*].binds.name",
      "op": "changed",
      "title": "POST /orders(.:format): sql_writes[*].binds.name changed",
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
