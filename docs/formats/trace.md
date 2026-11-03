# Format: trace (trace_version 1)

One trace per replayed request, produced inside a twin by the recorder
(`docs/design/recorder.md`). In M1, traces travel in the `run_session` result
(protocol schema_version 2). From M3 they're also written to
`results/<run_id>/traces/`.

All keys are strings. Absent channels are empty arrays, never missing. Timestamps are
ISO 8601 UTC with microseconds.

```json
{
  "trace_version": 1,
  "request": {
    "index": 0,
    "method": "POST",
    "path": "/orders.json",
    "params": {"email": "ada@example.com", "total_cents": 1999},
    "headers": {}
  },
  "response": {
    "status": 201,
    "headers": {"content-type": "application/json; charset=utf-8", "location": "http://www.example.com/orders/1"},
    "body": {"encoding": "utf-8", "data": "{\"id\":1,...}"}
  },
  "exception": null,
  "sql_writes": [
    {
      "statement": "INSERT",
      "table": "orders",
      "name": "Order Create",
      "sql": "INSERT INTO \"orders\" (\"user_id\", \"total_cents\", ...) VALUES (?, ?, ...) RETURNING \"id\"",
      "binds": {"user_id": 1, "total_cents": 1999, "currency": "USD", "status": "pending",
                "created_at": "2026-11-03T00:00:00.000000Z", "updated_at": "2026-11-03T00:00:00.000000Z"}
    }
  ],
  "jobs": [
    {
      "event": "enqueue",
      "job_class": "OrderConfirmationJob",
      "queue_name": "default",
      "priority": null,
      "arguments": [{"_aj_globalid": "gid://shop/Order/1"}],
      "scheduled_at": null
    }
  ],
  "mail": [
    {
      "mailer": "OrderMailer",
      "to": ["ada@example.com"], "from": ["from@example.com"], "cc": [], "bcc": [],
      "subject": "Order #1 cancelled",
      "text_body": "Hi Ada, ...",
      "html_body": "<p>Hi Ada, ...</p>",
      "attachments": []
    }
  ],
  "cache": [
    {"op": "delete", "key": "orders/summary"},
    {"op": "write", "key": "orders/summary", "value": {"count": 1, "total_cents": 1999}}
  ],
  "http": [
    {
      "method": "GET",
      "url": "https://rates.example.test/latest?base=USD&symbols=EUR",
      "request_headers": {"accept-encoding": ["..."]},
      "request_body": null,
      "stubbed": true,
      "response": {"status": 200, "headers": {"content-type": ["application/json"]}, "body": "{...}"}
    }
  ],
  "duration_ms": 12.3
}
```

## Fields

| Field | Notes |
|---|---|
| `exception` | `null`, or `{"class", "message", "backtrace"}` (first 10 frames) when the app raised an exception it didn't rescue. Then `response` is `null`. |
| `sql_writes[].binds` | Column name → value as sent to the database. Binary values are `{"binary_sha256": ...}`. Statements with inline literals have `{}`. |
| `jobs[].event` | `enqueue`, `enqueue_at`, or `enqueue_all` (one entry per job). |
| `cache[].op` | `write`, `delete`, `increment`, `decrement`. Multi-key events are expanded to one entry per key. `value` only on writes; values that can't be represented as JSON become their `inspect` string. |
| `http[].response` | The response the interceptor returned: the stub's, or the synthetic block `{"status": 503, "headers": {"x-doubletrack": ["blocked"]}, "body": ""}`. |
| `duration_ms` | Wall time of the request inside the twin. Informational; never diffed. |

## Compatibility

`trace_version` is bumped on any incompatible change. Readers must ignore unknown keys.
