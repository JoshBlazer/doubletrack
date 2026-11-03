# Design note: coordinator ↔ twin protocol

Status: **accepted**. Current schema_version: **3** (M2, ADR 0016); v2 was M1 (ADR 0013), v1 was M0. Owner: core. Related ADRs: 0002, 0003, 0013, 0016. M2 details: [`replay.md`](replay.md).

## Problem

The coordinator (the `doubletrack` CLI process) must drive three long-lived Rails
processes ("twins") that each run a *different* bundle: control A, control A′ (both the
current Rails), and candidate B (the next Rails). It needs to:

1. Know that each twin has booted, and what it actually booted (Ruby, Rails, app, role).
2. Send work (snapshot preparation, sessions to replay) and receive structured results.
3. Detect hangs and crashes without hanging itself.
4. Never be confused by whatever the target app prints. Rails apps, their gems and
   their initializers write freely to stdout/stderr.

## Transport

* Two anonymous pipes per twin, created by the coordinator with `IO.pipe`:
  * **coordinator → twin**: the twin reads from **fd 3**.
  * **twin → coordinator**: the twin writes to **fd 4**.
* The twin is started with `Process.spawn(env, *argv, 3 => req_r, 4 => res_w, chdir: app_root)`.
  The fd numbers are also passed in the environment as `DOUBLETRACK_FD_IN=3` and
  `DOUBLETRACK_FD_OUT=4`, so the twin never hard-codes them.
* After spawning, the coordinator closes its copies of the child's pipe ends (`req_r`,
  `res_w`). EOF on the twin→coordinator pipe then reliably means the twin is gone.
* **Before loading the app**, the twin reopens `$stdout`/`$stderr` (fds 1 and 2) onto
  `<work_dir>/twin-<role>.log`. Anything the app prints, including output from
  subprocesses it spawns, goes to that log, never to the protocol.
* Only POSIX platforms are supported: Linux and macOS. Windows can't map fds above 2
  into a child process through `spawn`; use WSL (ADR 0003).

## Framing

* Newline-delimited JSON (NDJSON). One message is one `JSON.generate` line terminated by
  `\n`. `JSON.generate` escapes control characters, so a message can never contain a raw
  newline.
* Encoding: UTF-8. Binary payloads (for example non-UTF-8 response bodies) are carried as
  `{"encoding": "base64", "data": "..."}`. Valid UTF-8 text uses `{"encoding": "utf-8", "data": "..."}`.
* Maximum frame size: **64 MiB**. The reader refuses longer lines and treats that as a
  protocol error, so a runaway response can't exhaust coordinator memory.
* Unknown top-level fields are ignored; this is the forward-compatibility rule.
  Unknown `type` values cause an `error` reply (from the twin) or a protocol error
  (in the coordinator).

## Envelope

Every message has the same envelope:

```json
{"schema_version": 1, "id": "c-000001", "type": "run_session", "reply_to": null, "payload": {}}
```

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Bumped on any incompatible change. Both sides check it on every message. |
| `id` | Unique per sender. The coordinator uses `c-NNNNNN`; the twin uses `t-NNNNNN`. |
| `type` | One of the message types below. |
| `reply_to` | The `id` of the request this answers, or `null`. |
| `payload` | Type-specific object. |

## Messages

| Type | Direction | Reply | Payload |
|---|---|---|---|
| `hello` | twin → coord, unsolicited, first message | none | `role`, `pid`, `ruby_version`, `ruby_platform`, `rails_version`, `rails_env`, `app` (`name`, `root`), `bundle_gemfile`, `session_cookie`, `routes[]` (`verb`, `path`, `name`, `controller`, `action`), `boot_ms` |
| `prepare_snapshot` | coord → twin | `result` / `error` | `template_path`, `seed`, `seeds` (bool): build the template from `db/schema.rb` (+ `db/seeds.rb`) with `VACUUM INTO`. Result: `template_path`, `bytes`, `sha256`, `tables` (name → rows). |
| `run_session` | coord → twin | `result` / `error` | `options`: `perform_jobs` (default true). `session`: `id`, `started_at`, `seed`, `snapshot` (template path or null), `requests[]` (`method`, `path`, `headers`, `params`, `offset_ms`, optional `as`, e.g. `"json"`), optional `http_stubs[]` (`method`, `url`, `match`: `exact`\|`prefix`, `status`, `headers`, `body`) |
| `result` | twin → coord | none | For `run_session`: `session_id`, `traces[]` (one per request, `docs/formats/trace.md`). An app exception is recorded inside its trace, not sent as `error`. |
| `error` | twin → coord | none | `code`, `message`, `exception_class`, `backtrace[]` (first 20 frames) |
| `shutdown` | coord → twin | `result` (`{"ok": true}`) then exit 0 | `{}` |

Error codes: `boot_failed` (sent instead of `hello` when the app can't boot, with
`reply_to: null`), `bad_message`, `unknown_type`, `schema_mismatch`, `not_implemented`,
`session_failed` (an exception escaped the request pipeline itself; normal 500 responses
are *results*, not errors).

## Lifecycle

```
coordinator                                twin
-----------                                ----
IO.pipe x2, Process.spawn  ───────────▶   redirect fd1/2 to log
                                           bundler/setup (app bundle), boot Rails
                          ◀───────────    hello            (or error boot_failed)
check schema_version, record versions
run_session  c-000001     ───────────▶
                          ◀───────────    result  reply_to c-000001
shutdown     c-000002     ───────────▶
                          ◀───────────    result  reply_to c-000002 ; exit 0
Process.wait
```

The twin handles one request at a time; the protocol is strictly request/response after
`hello`. Concurrency comes from running more twins (later: N triplets), never from
pipelining inside one twin. This keeps determinism controls simple.

## Timeouts and crash detection (coordinator side)

* **Boot timeout**: default 120 s for `hello`, configurable with `boot_timeout`. Large
  apps boot slowly.
* **Request timeout**: default 60 s per reply, configurable with `request_timeout`.
* Reads use `IO.select` with the remaining deadline, so a silent twin can't block the
  coordinator.
* **EOF** on the twin→coordinator pipe, or a twin that has exited (`Process.wait2` with
  `WNOHANG`), raises `TwinCrashed`, which includes the exit status and the last 40 lines
  of the twin log.
* On timeout the coordinator sends `TERM`, waits 5 s, then sends `KILL`, and raises
  `TwinTimeout` with the log tail.
* Every coordinator-side failure maps to CLI exit code **2** (Doubletrack error).

## Environment hygiene

* Twins are spawned inside `Bundler.with_unbundled_env` (when Bundler is loaded in the
  coordinator), with `BUNDLE_GEMFILE` set explicitly per role: `Gemfile` for A/A′ and
  `Gemfile.next` for B. `RUBYOPT` and `RUBYLIB` are cleared so the coordinator's
  `-rbundler/setup` can't leak in.
* The twin entry point (`lib/doubletrack/twin/main.rb`) uses **only the standard library**
  until the app's bundle is loaded, because Doubletrack is not in the target app's
  Gemfile. It needs `json` (a default gem) and base64 via `Array#pack("m0")`; the
  `base64` gem is no longer a default gem in Ruby 3.4+, so the twin avoids it.
* Boot order inside the twin: redirect fds 1/2 → `require "bundler/setup"` (the app's
  bundle) → `require "json"` → boot Rails. `json` is loaded *after* Bundler so an app
  that pins a different `json` version doesn't hit a "gem already activated" conflict.

## Testing plan (written before implementation)

1. `spec/doubletrack/protocol/framing_spec.rb`: round-trips messages; rejects frames over
   the limit; rejects invalid JSON with a `ProtocolError`; handles partial reads (a message
   split across `write` calls); encodes binary bodies as base64.
2. `spec/doubletrack/protocol/message_spec.rb`: envelope validation (missing fields,
   wrong schema_version, unknown type).
3. `spec/doubletrack/coordinator/twin_process_spec.rb`, using a **fake twin**: a tiny Ruby
   script speaking the protocol. Cases: happy path; stdout noise does not corrupt the
   protocol; the twin crashes before `hello` → `TwinCrashed` with the log tail; the twin
   hangs → `TwinTimeout` within the deadline; a `boot_failed` error is surfaced.
4. Integration (M0 exit check): `bin/doubletrack-spike fixtures/apps/shop` boots the real
   app on both Rails versions.

## Open questions

* Should results be streamed per request (for progress bars on long sessions)? Deferred.
  Adding a `progress` message type later is backward compatible.
* Binary-safe framing (length-prefixed) is unnecessary while JSON escapes everything.
  Revisit if profiling shows JSON encoding of large bodies dominates.
