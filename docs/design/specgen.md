# Design note: reproduction specs and the baseline (M4)

Status: **accepted for M4**. Related: ADR 0022 (repros replay through a twin process),
ADR 0023 (repros verified and minimized during the run), ADR 0024 (baseline
semantics), `docs/formats/repros.md`, `docs/formats/baseline.md`.

## Goal

Every new finding gets a small test the user can run in their own app. It **passes on
the current Rails and fails on the next one**, and it shows the requests and the value
that changed. A finding the team decides is expected can be accepted with
`doubletrack accept ID --reason "..."`. That writes `doubletrack.baseline.yml` (committed
to the app's repo), and later runs report only new findings.

**Exit check** (ROADMAP):
* a generated spec passes on old and fails on new, checked by actually running it with
  `bundle exec` on both Gemfiles (RSpec and Minitest);
* after `accept`, the next `doubletrack run` reports the finding as accepted, not new,
  and exits 0.

## What a reproduction is

A reproduction is a finding, reduced to data:

| Field | Source |
|---|---|
| `finding_id`, `title`, `severity` | the finding |
| `session_id`, `seed`, `started_at`, `http_stubs` | the occurrence's session (same per-session seed as the run) |
| `requests` | the session's requests **up to and including** the finding's request, then minimized (below) |
| `segments` | the concrete path of the difference, as an array (`["sql_writes", 0, "binds", "name"]`), relative to the last request's normalized trace |
| `expected` | control A's normalized value there, or *absent* for an `added` difference |
| `observed` | what A, A′ and B produced when the run verified it |
| `snapshot` | the run's database template (content-addressed copy) |
| `normalize` | the normalization options of the run (`ignored_headers`, `ignored_columns`) |

The occurrence used is the one with the **smallest request index**, which gives the
shortest replay. Ties go to the first in run order.

Reproductions are stored in `results/<run_id>/repros.json`. The spec files are rendered
from that data, so `doubletrack report` can re-render them without twins.

## How a generated spec runs (ADR 0022)

```ruby
require "doubletrack/repro"

RSpec.describe "Doubletrack f-…: GET /orders/:id(.:format) exception.message changed" do
  it "keeps the Rails 8.0.5.1 behavior" do
    replay = Doubletrack::Repro.replay(
      snapshot: File.expand_path("snapshots/1a2b3c4d5e6f.sqlite3", __dir__),
      started_at: "2026-01-01T00:00:00Z", seed: 1234, perform_jobs: true,
      requests: [{"method" => "GET", "path" => "/orders/1.json", ...}],
      http_stubs: []
    )
    expect(replay.last.at("exception", "message")).to eql("unexpected token at ''")
  end
end
```

The comparison is as strict as verification (`Repro.same?`: `1` is not `1.0`): `eql`
in RSpec; in Minitest, `assert(Doubletrack::Repro.same?(expected, actual), ...)` with
Minitest's diff as the message, since `assert_equal` would compare with `==`.

`Doubletrack::Repro.replay` starts **one twin process** of the app with the Gemfile of
the current `bundle exec` (`ENV["BUNDLE_GEMFILE"]`). It is the same entry point,
environment overlay, clock, seeding, HTTP interception, job performing and recorder as
`doubletrack run`. It runs the requests as one session on a copy of the snapshot,
normalizes the traces with the run's options, and returns them. The twin is reused by
every repro in the same test process and stopped at exit.

So the spec process itself never boots Rails. `bundle exec rspec` with the app's own
`rails_helper` loaded (test environment) still works, and so do Minitest and plain
`ruby`. Version selection is the dual-boot convention the user already has:

```
bundle exec rspec spec/doubletrack/f-…_spec.rb                         # passes (current)
BUNDLE_GEMFILE=Gemfile.next bundle exec rspec spec/doubletrack/f-…_spec.rb   # fails (next)
```

`Repro::Trace#at(*segments)` returns the value, or `Doubletrack::Repro::ABSENT` (which
inspects as `<absent>`) if the path doesn't exist. Expected values are written as Ruby
literals (`inspect` of JSON-compatible data), and as a `JSON.parse` heredoc when they're
longer than 300 characters.

**Framework.** Config key `repro_framework`: `auto` (default), `rspec` or `minitest`.
`auto` picks RSpec if the app has a `spec/` directory and `rspec-core` is in
`Gemfile.lock`. Otherwise it picks Minitest. Files:
* RSpec: `repro/spec/doubletrack/<id>_spec.rb`
* Minitest: `repro/test/doubletrack/<id>_test.rb`, run with `bundle exec ruby -Itest <file>`

Both sit next to a `snapshots/` directory, referenced relative to the file (`__dir__`),
so the directory can be copied into the app unchanged, or run in place from the results
directory.

**Requirement on the app:** the gem in its test group, in its Gemfile (until release:
`gem "doubletrack", github: "JoshBlazer/doubletrack", require: false, group: :test`), so `require "doubletrack/repro"` works under `bundle exec`. If it's missing,
the generated file raises a `LoadError` that says exactly that.

## Verification and minimization during the run (ADR 0023)

After the analysis, while the three twins are still running, `doubletrack run` checks
each new finding's reproduction with the same code the spec uses:

* **reproduces** ⇔ the value at `segments` in the last trace equals `expected` on
  control A **and** on control A′, and differs on candidate B.

Steps:
1. Truncate the session after the finding's request. Replay on A, A′ and B. If it
   doesn't reproduce (for example, it depends on a later request), the repro is stored
   with status `not_reproduced` and the observed values. It's still rendered, but the
   report says plainly that it wasn't verified.
2. Greedy one-pass minimization: try dropping each earlier request, last to first. Keep
   the drop if it still reproduces. A request is kept only when it's needed. At most
   `MAX_MINIMIZE_STEPS` (20) attempts per finding, and earlier requests beyond that are
   kept.
3. Store `requests_before` (prefix length) and `requests_after`.

Cost: at most 1 + 20 three-way session replays per finding, on twins that are already
booted. A replay of a short session takes milliseconds to a few hundred ms.

The run copies the snapshot template into `repro/<dir>/snapshots/<sha256[0,12]>.sqlite3`
before deleting its work files.

Accepted findings (below) get no repro: they're expected.

## Baseline (ADR 0024)

`doubletrack.baseline.yml` in the app root (format: `docs/formats/baseline.md`):

```yaml
baseline_version: 1
accepted:
  - id: f-bb3068808cf1
    title: "GET /orders/:id(.:format): exception.message changed"
    severity: user-visible
    reason: "We never show parser messages to users"
    author: "Josh Blazer <josh@example.com>"
    accepted_at: "2026-11-03T09:00:00Z"
    rails: "8.0.5.1 → 8.1.4"
```

* `doubletrack accept ID --reason TEXT [APP_DIR] [--results DIR] [--author TEXT]`
  * Looks up `ID` in the newest results directory under `APP_DIR/tmp/doubletrack`
    (or `--results`). An unknown ID is an error, so typos can't create dead entries.
  * The reason is required and must not be blank.
  * The author comes from `--author`, else `git config user.name`/`user.email` in the
    app, else it's an error.
  * Re-accepting an ID replaces its entry and says "updated".
  * Entries are kept sorted by id, so diffs stay small.
* Analysis (both `run` and `report`) reads the baseline from the app root.
  * A finding whose id is listed gets `"accepted" => {reason, author, accepted_at}`.
  * Counts and the verdict use **new** findings only. Accepted ones are counted
    separately.
  * Baseline entries that weren't observed in this run are listed as **stale** in
    `run.json` and in the report. They aren't errors, because the session that
    triggered them may simply not have run.
* Exit code: 1 only if there are new findings.
* The finding id is the fingerprint (ADR 0019): channel, route, generalized path, op and
  value shape. It's stable across runs, so the same root cause keeps its id. A changed
  value at an enumerated leaf (for example a status `200 → 500` instead of
  `200 → 422`) is a different finding, so it isn't hidden by an old acceptance.

## Report changes

* Overview: new findings by severity, plus "N accepted" and "N stale baseline entries".
  The verdict is based on new findings.
* Findings page: new findings by severity, then an "Accepted" section with reasons.
* Finding page:
  * the generated spec (copyable), with its verification status ("Verified in this run:
    passes on 8.0.5.1, fails on 8.1.4") and the minimization result ("3 → 1
    requests");
  * the run-in-place and copy-into-app commands;
  * the `accept` command, or the acceptance details if it's already accepted.

## Failure modes

| Case | Behavior |
|---|---|
| Finding doesn't reproduce in isolation | `status: not_reproduced` with observed values; the report says it wasn't verified |
| Baseline file malformed | `doubletrack run`/`report` exit 2 with the parse error (silently ignoring it could hide findings) |
| `accept` with no results directory | exit 2: "run `doubletrack run` first" |
| Spec run without the gem in the app bundle | `LoadError` naming the Gemfile line to add |
| Spec run on a non-SQLite app | Not possible in the MVP: snapshots are SQLite only (M2 limitation) |

## Not in M4

* Rewriting the repro as an idiomatic `rails_helper` request spec. The replay-based
  spec is the faithful one. A hand-written request spec may behave differently
  (`test` vs `doubletrack` environment).
* Minimizing `http_stubs` or request params. Delta debugging below single-request
  granularity.
* Writing specs into the app automatically. Doubletrack doesn't change the user's
  code (PRODUCT). `accept` writes only the baseline file, which is the command's
  explicit purpose.
