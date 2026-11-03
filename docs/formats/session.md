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
| `snapshot` | no | `"default"` (the default): the template built from `db/schema.rb` (plus `db/seeds.rb` when `seeds: true`). `"fixtures"` (M5, ADR 0026): `db/schema.rb` plus every fixture file under `test/fixtures` or `spec/fixtures`, which is the state the app's tests start from. Captured sessions use it. |
| `requests[]` | yes, ≥ 1 | Each request: `method` (default `GET`; one of GET POST PUT PATCH DELETE HEAD), `path` (required, starts with `/`), `params` (object), `headers` (object), `as` (e.g. `"json"`: encode params as a JSON body), `offset_ms` (integer ≥ 0, non-decreasing; default `1000 × index`), `test_status` (M5, informational: the HTTP status, or `"raised"`, that the request got in the test it was captured from; never sent to twins, used for capture fidelity, ADR 0027). |
| `http_stubs[]` | no | Canned outbound responses; see `docs/design/protocol.md`. Unmatched calls get the synthetic 503. |

Unknown keys are rejected with the file and line number, so a typo can't silently
change what gets replayed. Readers of a *newer* `session_version` refuse the file.

## Where sessions come from

* **Hand-written.** The fixtures ship theirs in `fixtures/apps/*/doubletrack/sessions/`.
* **Captured (M5).** `doubletrack capture` runs the app's integration tests and request
  specs and writes `doubletrack/sessions/captured.jsonl`: one session per test, on the
  `fixtures` snapshot, with `test_status` on every request.
  * HTTP stubs from `doubletrack/http_stubs.json` (a JSON array in the `http_stubs[]`
    format) are added to every captured session.
  * Values of secret-looking environment variables are redacted (ADR 0027, RISKS R8).
  * The file is regenerated on every capture, so don't hand-edit it.

  Design: `docs/design/capture.md`.
