# Format: baseline (`doubletrack.baseline.yml`, baseline_version 1)

Committed to the **app's** repository, in its root. Written by `doubletrack accept`, and
read by `doubletrack run` and `doubletrack report`. Design: `docs/design/specgen.md`,
ADR 0024.

```yaml
# Doubletrack baseline: findings accepted as expected upgrade differences.
# Written by `doubletrack accept`. Review changes to this file like code.
baseline_version: 1
accepted:
- id: f-bb3068808cf1
  title: 'GET /orders/:id(.:format): exception.message changed'
  severity: user-visible
  reason: We never show parser messages to users
  author: Josh Blazer <josh@example.com>
  accepted_at: '2026-11-03T09:00:00Z'
  rails: 8.0.5.1 → 8.1.4
  run_id: 20261103T072146Z-42
```

| Field | Required | Notes |
|---|---|---|
| `baseline_version` | yes | `1` |
| `accepted[].id` | yes | Finding id (`f-` + 12 hex), the fingerprint from ADR 0019. Unique. |
| `accepted[].reason` | yes | Non-blank. Why this difference is expected. |
| `accepted[].author` | yes | `--author`, or `git config user.name <user.email>` |
| `accepted[].accepted_at` | yes | ISO 8601 UTC |
| `title`, `severity`, `rails`, `run_id` | no | Context for reviewers, copied from the finding. Never used for matching. |

Rules:
* Matching uses `id` only.
* Entries are sorted by `id`.
* Unknown keys, duplicate ids, a blank reason, or YAML that isn't a mapping are errors
  (exit 2). A malformed baseline must never silently hide or show findings.
* An entry not observed in a run is reported as **stale**. It is kept, because the
  sessions that triggered it may simply not have been replayed.
