# Data formats

Each versioned format gets a spec here as it is built:

| Format | Milestone | Spec |
|---|---|---|
| Coordinator ↔ twin protocol (schema_version 3) | M0–M2 | [`../design/protocol.md`](../design/protocol.md) |
| Trace (trace_version 2) | M1, M2 | [`trace.md`](trace.md) |
| Session (`sessions/*.jsonl`, session_version 1) | M2 | [`session.md`](session.md) |
| Findings (`results/<run_id>/findings.json`, findings_version 1) | M3 | [`findings.md`](findings.md) |
| Run metadata (`results/<run_id>/run.json`, run_version 1) | M3 | [`run.md`](run.md) |
