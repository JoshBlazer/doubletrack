# Design note: side-effect recorder (M1)

Status: **accepted for M1**; extended in M2 (trace v2, jobs performed inline: see [`replay.md`](replay.md)). Related: ADR 0011 (cache store), ADR 0012 (HTTP interception),
`docs/formats/trace.md` (output), `docs/design/protocol.md` (schema_version 2).

## Goal

For every replayed request, produce one **trace**: a JSON document holding the
response and every side effect the request caused, on the channels the brief names:
SQL writes, enqueued jobs, delivered mail, cache writes/deletes, and outbound HTTP.
Traces are raw evidence. Normalization (M2–M3) and diffing (M3) work on them later, so
the recorder keeps everything and judges nothing.

## Where it runs

Inside the twin, after the app has booted. `lib/doubletrack/recorder/` may use
ActiveSupport (always present in a Rails app) but no other gems. The HTTP interceptor
uses only `net/http` and is installed **before** the app boots, so even boot-time HTTP
calls are blocked.

## API

```ruby
recorder = Doubletrack::Recorder::Recorder.new(http_stubs: [...])
trace = recorder.capture(request_index, request_hash) do
  integration_session.get("/orders")   # anything the app does in here is recorded
end
# => Hash following docs/formats/trace.md
```

`capture`:
1. Subscribes to `sql.active_record`, `enqueue.active_job`, `enqueue_at.active_job`,
   `enqueue_all.active_job`, `deliver.action_mailer`, `cache_write.active_support`,
   `cache_write_multi.active_support`, `cache_delete.active_support`,
   `cache_delete_multi.active_support`, `cache_increment.active_support`,
   `cache_decrement.active_support`.
2. Points the HTTP interceptor at this recorder.
3. Yields. If the app raises (exceptions the app doesn't rescue), the exception is
   recorded in the trace and **not** re-raised, because "this request now raises" is a
   behavior to compare, not a Doubletrack failure.
4. In `ensure`: unsubscribes everything and detaches the interceptor, even if the block
   raised.
5. After unsubscribing, reads back the values of cache keys written during the request
   (so the read itself isn't recorded) and pairs mail events with
   `ActionMailer::Base.deliveries` to get bodies.

## Channel rules

| Channel | Source | Kept | Dropped (and why) |
|---|---|---|---|
| SQL | `sql.active_record` | `INSERT`/`UPDATE`/`DELETE`/`REPLACE` statements: raw SQL, table, statement kind, binds by column name | reads; `SCHEMA` queries; cached queries; `BEGIN`/`COMMIT`/`SAVEPOINT` (transaction shape is not behavior we compare in v1) |
| Jobs | `enqueue*.active_job` | job class, queue, priority, serialized arguments (GlobalIDs stay as `gid://` strings), scheduled_at | `job_id`, `enqueued_at`, `provider_job_id` (always random/volatile) |
| Mail | `deliver.action_mailer` + `ActionMailer::Base.deliveries` | mailer, to/from/cc/bcc, subject, text and HTML bodies, attachment filenames | `Message-ID`, `Date` headers (volatile) |
| Cache | `cache_*.active_support` | operation, key (namespaced as the store reports it), value read back after the request for writes | values for `increment`/`decrement` (the event carries the amount) |
| HTTP | interceptor | method, URL, request headers, request body, the response returned, whether a stub matched | nothing; **no request ever reaches the network** |
| Response | integration session | status, all headers, body (UTF-8 or base64) | nothing; header selection is the normalizer's job (M3), so raw evidence is kept |

## Sandbox guarantees (hard constraint 8)

* Mail: `delivery_method = :test` (overlay). Recorded, never delivered.
* Jobs: `queue_adapter = :test` (overlay). Recorded, never pushed to a real queue. (M1
  didn't perform them; since M2 they are performed inline after their request, ADR 0014.)
* HTTP: `Net::HTTP#connect` is replaced with a no-op and `Net::HTTP#request` with a
  lookup: a matching stub's response, or a synthetic `503` with header
  `x-doubletrack: blocked`. Libraries that don't use `Net::HTTP` (curl bindings, raw
  sockets) are **not** covered yet (RISKS R6).

## Per-session reset (M1 subset of M2)

At the start of each `run_session`: `Rails.cache.clear`,
`ActionMailer::Base.deliveries.clear`, and the test queue adapter's job lists are
cleared. **The database was not reset in M1**; since M2 every session restores a
snapshot (ADR 0004).

## Tests written before the implementation

`spec/integration/recorder_spec.rb` (tagged `integration`) boots the real `shop` app on
**both** twins and replays one session:

1. `POST /orders.json` → 201; SQL writes include `INSERT` into `users` and `orders` with
   `total_cents = 1999`; one `OrderConfirmationJob` whose argument is the order's GlobalID;
   a cache delete of `orders/summary`; no mail; no HTTP.
2. `GET /orders` → a cache write of `orders/summary` with value
   `{"count" => 1, "total_cents" => 1999}`; no SQL writes.
3. `GET /orders/1.json?currency=EUR` with a stub for `https://rates.example.test/latest` →
   one recorded HTTP call, `stubbed: true`, and the converted price in the body.
4. `GET /orders/1.json?currency=GBP` with **no** stub → the call is recorded as blocked
   (`stubbed: false`, synthetic 503), and the app's resulting exception is recorded in
   the trace instead of failing the session.
5. `PATCH /orders/1/cancel` → an `UPDATE` of `orders.status` and one delivered mail to
   the customer with subject `Order #1 cancelled`.

Plus unit specs for the HTTP interceptor (stub matching, blocking, no socket opened) and
the JSON-safe value converter.
