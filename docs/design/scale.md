# Design note: capture fidelity and scale (M12)

Status: **accepted for M12**. Related: ADR 0039 (raw bodies, uploads and hosts in
sessions), ADR 0040 (parallel slots), ADR 0025–0027 (capture), ADR 0037.

## Goal

On Campfire, capture skipped 26 tests:
* 23 posted a raw string body (`post url, params: +"Hello Bot World!"`);
* 3 uploaded a file (`fixture_file_upload`).

Requests to another host (`host!`, or full URLs) replayed on `www.example.com`, so routes
constrained to a subdomain didn't match. Replay also ran one session at a time, so a big
app's run took as long as all its sessions in a row.

**Exit check** (ROADMAP):
* shop gains tests that post a raw body, upload a file and call a host-constrained route;
  capture keeps all of them and replays them with **capture fidelity 100%**
  (`spec/integration/capture_spec.rb`);
* `doubletrack run --parallel 2` on shop gives the same finding ids as a serial run.

## Sessions: raw bodies, uploads, hosts (ADR 0039)

New optional request fields (`docs/formats/session.md`):

| Field | Meaning |
|---|---|
| `body` | A raw request body (UTF-8 text). Sent as the request body instead of `params`. |
| `body_base64` | The same, for bodies that aren't valid UTF-8. |
| `host` | The request's host (default `www.example.com`, as integration tests use). |
| `https` | `true` for an HTTPS request. |

An upload is a value inside `params`:
`{"$upload": {"filename": "moon.jpg", "content_type": "image/jpeg", "data_base64": "…"}}`.
The twin writes it to a temporary file in its work directory and passes a
`Rack::Test::UploadedFile`, which is what `fixture_file_upload` makes in a test.

**Capture.**
* `Record.build` turns a String `params` into `body` / `body_base64`, and an object that
  responds to `original_filename` and `path` into an `$upload` (read from its path, so the
  test's IO isn't consumed). Files over 5 MB stay unsupported.
* The probe records the session's `host` and `https?` with each request.
* A full URL in the path wins over the session host, as in Rails.
* The assembler keeps `host` only when it isn't the default.

**Replay.** Before each request the worker sets `integration.host` and `https!` from the
request, falling back to the defaults. The session is reused across requests, so a request
with a host must not leak it to the next one.

## Parallel slots (ADR 0040)

`--parallel N` (`parallel: N` in `doubletrack.yml`, default 1) boots N *slots*. Each slot
has its own control A, A′ and candidate B. Sessions are dealt to slots from a shared queue,
and each finished session's traces are written as before. Every session restores the
snapshot first, so the slot a session runs in can't change its traces, and finding ids
don't depend on N.

* Slot 0 builds the snapshot templates. The other slots restore from the same template
  file (SQLite) or template database (PostgreSQL: template names come from the run's work
  directory, so all slots share them).
* Each slot has its own private databases: `<role>.sqlite3` for slot 0 and
  `<role>-<slot>.sqlite3` for the others; for PostgreSQL, `dt_<hash>_<role>` and
  `dt_<hash>_<role>_<slot>`.
* Reproductions are verified on slot 0 after replay, as before.
* Boot time and memory grow with N (3 × N app processes). The run prints slot timings.

## Limitations

* Uploads are embedded in the sessions file as base64; 5 MB per file at most.
* Requests that set Rack env other than headers, the host and HTTPS are still skipped.
* Parallel slots multiply memory use. The default stays 1.
