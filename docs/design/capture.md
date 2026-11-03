# Design note: test-derived capture (M5)

Status: **accepted for M5**. Related: ADR 0025 (capture by hooking the integration
session), ADR 0026 (`fixtures` snapshot), ADR 0027 (redaction and capture fidelity),
`docs/formats/session.md`, RISKS R8, R15.

## Goal

Hand-written sessions don't scale, and the report is only as strong as its coverage.
Most Rails apps already have request or integration tests that exercise their routes.
`doubletrack capture` runs those tests once, on the current Rails, and turns the
requests they make into replay sessions. `doubletrack run` then replays them on A, A′
and B like any other session.

**Exit check** (ROADMAP): `doubletrack capture` on `shop` produces sessions from its
request tests, and `run` uses them. Made concrete:
* every shop integration test that makes requests becomes one session, with the same
  requests in the same order (method, path, params, `as`);
* `run` with only those sessions replays them, with **capture fidelity 100%**: each
  replayed request on control A gets the HTTP status the test saw. That includes a
  request to a fixture record's id, which only resolves because the snapshot contains
  the fixtures.

## How capture works (ADR 0025)

```
doubletrack capture APP
  └─ spawns the app's test command (default: `bin/rails test`, or `bundle exec rspec`
     when repro_framework resolves to rspec) with
       BUNDLE_GEMFILE=<current Gemfile>, RAILS_ENV=test,
       RUBYOPT="-r<gem>/lib/doubletrack/capture/boot.rb",
       DOUBLETRACK_CAPTURE_DIR=<private temp dir>
        └─ boot.rb (in the test process): require "bundler/setup", then
           ActiveSupport.on_load(:after_initialize)        → prepend Hook into
                                                             ActionDispatch::Integration::Session#process
           ActiveSupport.on_load(:action_dispatch_integration_test) → Minitest test names
           Each process call appends one JSON line to capture-<pid>.jsonl
           (works across parallel test workers: one file per forked pid)
  └─ Capture::Assembler: records → sessions (group, convert, redact, dedupe)
  └─ writes doubletrack/sessions/captured.jsonl (or --out)
```

`Integration::Session#process(method, path, params:, headers:, env:, xhr:, as:)` is
where every `get`, `post` and so on of a Minitest integration test or an RSpec request
spec ends up, including `follow_redirect!`. The hook records the call's arguments
*before* Rails encodes them. That's exactly the shape the twin replays (the twin calls
the same method). After the call it records `response.status`, or the exception class
if the request raised.

**Test identity:**
* Minitest: `"#{class}##{test name}"`, set by a `before_setup` hook.
* RSpec: `RSpec.current_example.full_description`.
* Fallback: the integration session's object id. Requests are grouped by test.

The hook is inert unless `DOUBLETRACK_CAPTURE_DIR` is set. It never changes arguments
or return values, and it never raises into the test: recording errors become a record
with `unsupported`.

## From records to sessions (`Capture::Assembler`, pure)

| Record | Session |
|---|---|
| `method` (symbol) | upcased; anything outside GET/POST/PUT/PATCH/DELETE/HEAD → the test is skipped (reason recorded) |
| `path` | URL host and scheme dropped, path and query kept |
| `params` | JSON round-tripped (symbols → strings). Non-JSON values (uploaded files, IO) or a raw string body → the test is skipped |
| `headers` | stringified. `xhr: true` adds `X-Requested-With` and the `Accept` Rails sets for xhr |
| `env` | `HTTP_*` keys become headers; any other key → the test is skipped |
| `as` | kept (`"json"`) |
| `status` | kept as `test_status` (informational, not sent to twins) |

* Session ids come from the test name: invalid characters become `-`, at most 100
  characters, and a short hash is added on truncation or collision.
* Sessions whose request lists are identical are written once. The duplicates are
  counted.
* Tests that made no requests produce nothing.
* Every captured session gets `"snapshot": "fixtures"`, plus the HTTP stubs from
  `doubletrack/http_stubs.json` if that file exists (config key `http_stubs`).

## The `fixtures` snapshot (ADR 0026)

Tests run against the test database with fixtures loaded. Captured requests reference
fixture ids (`/orders/#{orders(:paid).id}`). Fixture ids are deterministic (a hash of
the label), so a snapshot with the same fixtures resolves them.

* `Session` gains `snapshot: "fixtures"`, next to `"default"`.
* `doubletrack run` builds one template per snapshot kind in use, on control A:
  * `default`: schema, plus seeds if `seeds: true`;
  * `fixtures`: schema, plus every `*.yml` under `test/fixtures` (or `spec/fixtures`),
    loaded with `ActiveRecord::FixtureSet.create_fixtures`.
* `run.json` `snapshot` becomes `snapshots: {kind => {bytes, sha256, tables}}`.
* Each repro records its own snapshot file.

## Secrets and fidelity (ADR 0027)

Captured sessions are committed to the app's repo, so they must not carry secrets
(R8).
* **What capture can see:** only arguments the tests themselves pass, which is test
  data already in the repo.
* **The one real risk:** a test reads a real credential from the environment (for
  example `ENV["STRIPE_KEY"]`) and sends it in a header or param.
* **Redaction:** every string value in a record (params, headers, path) that contains
  the value of an environment variable whose name looks secret (`KEY`, `TOKEN`,
  `SECRET`, `PASSWORD`, `CREDENTIAL`, `AUTH`; values of 8+ characters) has that value
  replaced with `[REDACTED:NAME]`. The count is reported. The raw records live only in
  a temp directory that is deleted afterwards.

**Capture fidelity:** a captured session is only useful if replaying it does what the
test did.
* For every request with a `test_status`, `doubletrack run` compares it with control
  A's replayed status (`raised` if the request raised).
* The result goes in `run.json` as `capture_fidelity: {requests, matched, mismatches[]}`,
  and appears in the CLI summary and on the report's coverage page.
* A mismatch isn't a finding. It means the replay environment differs from the test
  environment for that request: an app-level stub, `sign_in` helpers, time-dependent
  setup.

## Command

```
doubletrack capture [APP_DIR] [--out FILE] [--command CMD]
```

* Exit 0 when sessions are written. Failing tests are a warning: their requests are
  still captured, and the summary says how many tests failed.
* Exit 2 on a Doubletrack error, when the command can't run, or when no requests were
  captured at all.
* Summary: tests that made requests, sessions written, requests, duplicates, skipped
  tests (with reasons), redactions, and the output path.

## Not in M5

* **Capturing outbound HTTP responses seen in tests** as stubs. Tests usually stub at
  the app level or with WebMock, and recording real responses would capture real data.
  Users provide `doubletrack/http_stubs.json`; unstubbed calls get the synthetic 503 in
  every twin, as before.
* **System tests** (browser-driven, Capybara): requests come from a real browser
  against a server thread. They aren't captured.
* **Auth helpers that bypass requests** (Devise `sign_in` via Warden test helpers):
  those tests' sessions replay unauthenticated. Fidelity reports this as a mismatch.
* **Production traffic capture** (middleware). That's a later layer (L3 area), with
  stronger scrubbing requirements (R8).
