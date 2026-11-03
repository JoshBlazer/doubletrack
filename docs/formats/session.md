# Format: session (`sessions/*.jsonl`, session_version 1)

A session is an ordered list of requests that share cookies. It is replayed from one
database snapshot (`docs/design/replay.md`). A sessions file is
[JSON Lines](https://jsonlines.org/): one session object per line. Blank lines and
lines starting with `#` are ignored. `doubletrack run` reads every `*.jsonl` file in the
sessions directory (default `doubletrack/sessions/` under the app root), in sorted
filename order.

```json
{"session_version": 1, "id": "checkout", "started_at": "2026-01-15T09:30:00Z",
 "requests": [
   {"method": "POST", "path": "/orders", "as": "json", "params": {"email": "ada@example.com", "total_cents": 1999}},
   {"method": "GET", "path": "/orders/recent", "offset_ms": 4000}
 ],
 "http_stubs": [
   {"method": "GET", "url": "https://rates.example.test/latest?base=USD&symbols=EUR", "match": "exact",
    "status": 200, "headers": {"content-type": "application/json"}, "body": "{\"rates\":{\"EUR\":0.9}}"}
 ]}
```

(Shown wrapped; in the file each session is one line.)

## Fields

| Field | Required | Notes |
|---|---|---|
| `session_version` | yes | `1`. |
| `id` | yes | Unique across the whole sessions directory. Pattern `[A-Za-z0-9._-]{1,100}`, because it's used in result file names. |
| `started_at` | no | ISO 8601. The clock is frozen here for the first request. Default `2026-01-01T00:00:00Z`, so replays don't depend on the wall clock. |
| `snapshot` | no | `"default"`, the only value in the MVP: the template built from `db/schema.rb` (plus `db/seeds.rb` when `seeds: true`). |
| `requests[]` | yes, ≥ 1 | Each request: `method` (default `GET`; one of GET POST PUT PATCH DELETE HEAD), `path` (required, starts with `/`), `params` (object), `headers` (object), `as` (e.g. `"json"`: encode params as a JSON body), `offset_ms` (integer ≥ 0, non-decreasing; default `1000 × index`). |
| `http_stubs[]` | no | Canned outbound responses; see `docs/design/protocol.md`. Unmatched calls get the synthetic 503. |

Unknown keys are rejected with the file and line number, so a typo can't silently
change what gets replayed. Readers of a *newer* `session_version` refuse the file.

## Where sessions come from

Hand-written in the MVP (fixtures ship theirs in `fixtures/apps/*/doubletrack/sessions/`).
M5 adds `doubletrack capture`, which derives sessions from the app's request tests.
Captured sessions can contain secrets, so capture scrubs them (RISKS R8).
