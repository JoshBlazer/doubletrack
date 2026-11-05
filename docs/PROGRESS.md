# Progress log

Append one entry per working session. Start every session by reading the latest
"What's next".

---

## 2026-11-03: Session 1 (scaffold + M0)

**Done**
* Name check: gem `doubletrack` is free on RubyGems (API 404, no similar names). Repo
  `JoshBlazer/doubletrack` is free. The GitHub org `doubletrack` exists (empty, created
  2019). The maintainer decided to proceed with the name.
* Toolchain: WSL Ubuntu 26.04, repo at `~/doubletrack`, Ruby 3.4.12 via rbenv. The
  maintainer installed the apt build dependencies.
* Docs: PRODUCT, ARCHITECTURE (draft), DECISIONS (ADRs 0001–0010), ROADMAP, RISKS
  (R1–R13), CLAUDE.md, README with status table, CHANGELOG, `docs/design/protocol.md`,
  `docs/walkthroughs/m0.md`.
* Gem skeleton with **zero runtime dependencies**: protocol (envelope + NDJSON framing),
  `Coordinator::TwinProcess`, twin entry point/worker, the `doubletrack` environment
  overlay, CLI skeleton, `bin/doubletrack-spike`, and the CI workflow (lint, unit matrix
  on Ruby 3.2–4.0, integration, gem build).
* `fixtures/apps/shop`: Rails 8.0.5.1 / 8.1.4 dual boot (next_rails convention), with users,
  orders, a mailer, a job (`after_create_commit`), cache, and an outbound HTTP call.

**Proven (commands; full output in `docs/walkthroughs/m0.md`)**
* `bin/doubletrack-spike fixtures/apps/shop` → both twins answer `GET /up` with 200;
  `hello` reports Rails 8.0.5.1 and 8.1.4; exit 0. Same with `--path /orders`.
* `bundle exec rake` → standardrb clean, 34 unit examples, 0 failures (3 runs with
  random ordering).
* `bundle exec rake spec:integration` → 3 examples, 0 failures.
* Shop's own tests: 5 runs, 0 failures on both Rails versions.
* `gem build doubletrack.gemspec` succeeds.

**Not proven / honest notes**
* **CI has never run**: there's no GitHub remote. M0 isn't done by the brief's
  definition until the `integration` job is green.
* The protocol design note came before the code, but the specs were written *alongside*
  the implementation in the same session, not strictly before it. The README's AI
  section says so.
* The spike's "same Rails version on both twins → exit 2" guard (R1) is untested
  against a real app.
* CI matrix entries for Ruby 3.2, 3.3 and 4.0 have never run anywhere; only 3.4.12 was
  used locally.

**What's next**
1. Maintainer: create the GitHub repo `JoshBlazer/doubletrack` and push, then confirm
   CI is green. Mark M0 done in README and ROADMAP only after that.
2. M1 design note: the trace format (`docs/formats/trace.md`) and recorder subscriber
   lifecycle, with failing integration tests against `shop` (POST /orders → SQL insert +
   enqueued `OrderConfirmationJob`; GET /orders → cache write).
3. ADR: switch the overlay's cache store from the app's `:null_store` to
   `:memory_store`, so cache writes are observable.
4. ADR: WebMock vs. a minimal `Net::HTTP` interceptor (needed by M1's outbound-HTTP
   recording, not only M2).

**Open questions**
* Should the `doubletrack` overlay offer a fallback to plain `RAILS_ENV=test` for apps
  that branch on `Rails.env.test?` (R12)?
* Per-app Ruby for twins (`.ruby-version`), or is "same Ruby as the coordinator" fine
  until M6?

**Blockers**
* None for local work. CI is blocked on the repo being created and pushed (the
  maintainer's call).

---

## 2026-11-03: Session 1, continued (CI)

**Done**
* Maintainer created the public repo `JoshBlazer/doubletrack`; `main` pushed.
* First CI run (41552751273) failed in two places:
  1. `rake spec:integration`: **real Bundler leak (R1)**. A coordinator without Bundler
     loaded passed `bundle exec`'s `GEM_HOME` to the twins. Fixed (always
     `Bundler.with_unbundled_env`), with a regression spec that failed before the fix.
  2. Ruby 3.2 `bundle install`: `parallel` 2.x needs Ruby 3.3; pinned `< 2` (dev only).
* Second run green on every job → **M0 marked done** in README, ROADMAP and walkthrough.

**Proven**
* CI [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904): lint, unit on Ruby 3.2/3.3/3.4/4.0 (35 examples), integration (spike exit 0
  plus 3 examples), gem build. All ✓.

**What's next** (unchanged from the entry above, items 2–4)
1. M1 design note: trace format + recorder lifecycle, with failing integration tests
   against `shop`.
2. ADR: overlay cache store `:memory_store` so cache writes are observable.
3. ADR: WebMock vs. minimal `Net::HTTP` interceptor.
4. Housekeeping: bump `actions/checkout` to a Node 24 release (CI warns that Node 20 is
   deprecated).

**Open questions**: as above. **Blockers**: none.

---

## 2026-11-03: Session 2 (M1, side-effect recorder)

**Done**
* Design first: `docs/design/recorder.md`, `docs/formats/trace.md`, ADR 0011 (fresh
  `:memory_store` per session), ADR 0012 (minimal `Net::HTTP` interceptor, no WebMock),
  ADR 0013 (protocol schema_version 2).
* Exit-check spec `spec/integration/recorder_spec.rb` written before the implementation
  and run red (12/12 failing).
* Recorder: SQL writes with binds by column, jobs (volatile fields dropped), mail with
  bodies, cache ops with read-back values, outbound HTTP (stubbed or blocked; no socket),
  response; app exceptions recorded in the trace instead of failing the session.
* shop gained `PATCH /orders/:id/cancel` (UPDATE + immediate mail) so every channel is
  exercised inside a request.
* Spike prints side-effect counts. CI uses `actions/checkout@v7`.

**Bugs found along the way (all with regression specs)**
* Property test: binary hash keys broke `JSON.generate` in the value converter.
* CI 41556048656 (Ruby 3.2/3.3): `Time#iso8601` needs `require "time"` before 3.4.
* Code review while fixing that: `Time#utc` mutated the app's `Time` objects in place;
  now `getutc`.
* My own spec bug: a prefix stub matched a URL meant to be blocked.

**Proven**
* CI [run 41556339580](https://github.com/JoshBlazer/doubletrack/actions/runs/41556339580): lint; unit on Ruby 3.2/3.3/3.4/4.0 (49 examples); integration 15 examples
  (M0 + M1 on both Rails versions); gem build. All ✓.
* Shop's own tests: 6 runs, 0 failures on 8.0 and 8.1.

**What's next: M2 (session replay)**
1. Design note `docs/design/snapshots.md` + failing tests: `VACUUM INTO` template,
   copy + reconnect per session (`prepare_snapshot`), replacing the boot-time schema load.
2. Determinism: freeze time at the session start and advance by recorded deltas; seed
   `Kernel#rand`; ADR on an optional deterministic `SecureRandom.uuid` sequence.
3. Session format `docs/formats/session.md` (`sessions/*.jsonl`).
4. Exit check: the same session replayed twice on the same version gives identical
   normalized traces. This needs a first normalizer (drop `x-request-id`/`x-runtime`,
   etc.); keep it minimal and property-tested, and leave the rest for M3.

**Open questions**
* Should jobs optionally be performed inline (a later option per the brief) before M3, so
  mail sent from jobs (the shop's confirmation email) is visible? Currently out of scope.
* The R12 and per-app-Ruby questions from session 1 are still open.

**Blockers**: none.

---

## 2026-11-03: Session 3 (M2, session replay)

The maintainer asked for M2 and M3 in one go, and for the jobs question: "do what would
be best for customers". Decision: perform jobs inline by default (ADR 0014).

**Done**
* Design first: `docs/design/replay.md`, `docs/formats/session.md`, and ADRs 0014 (jobs
  inline), 0015 (own clock; `SecureRandom` left to the noise mask) and 0016 (protocol v3).
* Specs committed red before the implementation: the exit check in
  `spec/integration/replay_spec.rb`, plus unit specs for the clock, the session loader
  and the normalizer.
* Built:
  * SQLite snapshots (`VACUUM INTO` template from control A, restored per session on
    every twin);
  * `Twin::Clock`, a seeded `rand` per session, and the `Session` loader;
  * `Normalize::Trace`;
  * trace v2 (`route`, `time`, `session`, `deprecations`, `performed_jobs`);
  * routes and the session cookie name in `hello`.
* shop gained `GET /orders/recent` (state carried in the session cookie).

**Bug found by the integration run**: freezing the clock at a session's `started_at`
while loading `schema.rb` made Rails 8.1 reject the migrations as "future". The template
is now built on the real clock, which is safe because it's shared by every twin.

**Proven**
* CI [run 41592499206](https://github.com/JoshBlazer/doubletrack/actions/runs/41592499206):
  lint, unit on Ruby 3.2/3.3/3.4/4.0 (83 examples), integration `32 examples, 0 failures`,
  and gem build, all ✓.
* Raw A vs A′ differences on the exit-check session are exactly the 5 known volatile
  fields (walkthrough m2 §3).

**What's next: M3**, in the same session.

---

## 2026-11-03: Session 3, continued (M3, diff, denoise, cluster, report)

**Done**
* Design first: `docs/design/diff.md`, `docs/formats/{findings,run}.md`, and ADRs 0017
  (Nokogiri), 0018 (severity), 0019 (mask and fingerprint) and 0020 (planted fixtures).
* Specs committed red before the implementation: normalizers, diff, mask, severity,
  fingerprint, cluster, analyzer, report, eval matcher, and the integration specs
  `run_spec.rb` and `eval_spec.rb`.
* Built:
  * `Normalize::{Json,Html,Sql}`, plus the extended `Normalize::Trace`;
  * `Diff::{Structural,NoiseMask,Severity,Fingerprint,Cluster,Analyzer}`;
  * `Config`, `Results`, `Coordinator::Run`, `Report::Site` (5 page types) and the CLI
    commands `run` and `report`;
  * `eval/harness.rb` and `make eval`.
* Fixtures:
  * `fixtures/apps/planted/{changes,clean}`: 9 version-gated plants, planted noise, and
    an irrelevant HTML change;
  * shop sessions in `fixtures/apps/shop/doubletrack/sessions/`.
* CI gained the `eval` job and the `report-a11y` job (axe on every report page).
* Added ADR 0021 (production error pages), after the first shop run.

**Found along the way**
* The first shop run gave 24 findings, 23 of them from Rails' debug exception page,
  plus 156 noise paths. Fixed with production error pages and one finding per HTML body
  per route. Now: 1 real finding (a `json` gem parser message change), 0 noise.
* The first eval run had precision 0.92. The unexpected finding was a real consequence
  of plant P9 (a `Date` header). The ground truth was updated, with the reason recorded.
* My axe CI step tested a comma-joined URL list as one page. Fixed to check each page
  separately.

**Proven**
* CI [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702): lint; unit on Ruby 3.2/3.3/3.4/4.0 (189 examples); integration
  `42 examples, 0 failures`; eval PASS (9/9, precision 1.00, clean 0); axe 5 pages, 0
  violations; gem build. All ✓.

**What's next: M4 (reproduction specs and baseline)**
1. Design note `docs/design/specgen.md` and failing tests. A generated RSpec request
   spec restores the run's snapshot through a helper shipped with the gem, replays the
   session up to the finding's request, and asserts the old value. It must pass on A
   and fail on B.
2. `doubletrack accept ID --reason`, the `doubletrack.baseline.yml` format, and runs
   that report only new findings. The exit code should count only new findings.
3. The report's "reproduction spec" and "accept" sections become real.

**Open questions**
* Sequence alignment for array diffs (one extra SQL write shifting later paths). Worth
  doing before M6's real app?
* Should a finding that appears on many routes, from one root cause, be grouped above
  route level in the report?
* R12 (fallback to the plain `test` env) and per-app Ruby are still open.

**Blockers**: none.

---

## 2026-11-03: Session 4 (M4, reproduction specs and baseline)

**Done**
* Design first: `docs/design/specgen.md`, `docs/formats/{repros,baseline}.md`, and
  ADRs 0022–0024:
  * 0022: repros replay through a twin process;
  * 0023: repros are verified and minimized during the run;
  * 0024: the baseline matches by id, and counts and the exit code use new findings.
* Specs committed red before the implementation (`edcd8be`).
* Built:
  * `Doubletrack::Repro`, the helper generated specs call;
  * `Specgen::{Writer,Minimizer,Generator}`;
  * `Baseline`;
  * `Results.compute/write`;
  * CLI `accept`, plus `run --baseline/--repro-framework`;
  * report sections: the spec with its verification, the run and copy commands, and
    the accepted and stale lists;
  * the eval `ReproCheck`, which runs every generated file on both Gemfiles.
* shop's Gemfile gained `doubletrack` (path) and `rspec` in its test group, as a real
  app would need.

**Found along the way**: two writer bugs, both caught by specs (a generated string
that didn't compile, and `Hash#inspect` format drift across Rubies). Also, the fixture
had `rspec-core` without `rspec-expectations`. Details in `docs/walkthroughs/m4.md`.

**Proven (locally)**
* Unit 263 examples; integration 52 examples, including `repro_spec.rb` (9).
* `make eval`: PASS, 13/13 repros confirmed (verified in the run, pass on 8.0, fail on
  8.1 when run under Minitest).
* CI [run 41714163293](https://github.com/JoshBlazer/doubletrack/actions/runs/41714163293): lint; unit on Ruby 3.2/3.3/3.4/4.0 (263 examples);
  integration `52 examples, 0 failures`; eval PASS with 13/13 repros confirmed; axe 5
  pages, 0 violations; gem build. All ✓. **M4 marked done.**

**What's next: M5 (test-derived capture)**
1. Design note `docs/design/capture.md`: a Rack middleware or integration-test hook that
   records request sequences from the app's own request/integration tests into
   `doubletrack/sessions/*.jsonl`. Includes scrubbing (R8) and stubs for outbound HTTP
   seen during tests.
2. `doubletrack capture` on shop, which produces sessions from its tests; `run` then
   uses them (the ROADMAP exit check).
3. Revisit R15 (snapshot contents) once sessions come from tests.

**Open questions**
* Should `doubletrack report` exit 1 when there are new findings, like `run` (today it
  always exits 0)?
* Should `accept` support `--all` for a first adoption on a big app? I left it out on
  purpose: every acceptance needs a reason.
* Sequence alignment for array diffs, and grouping above route level (from M3), are
  still open.

**Blockers**: none.

---

## 2026-11-03: Session 5 (M5, test-derived capture)

**Done**
* Design first: `docs/design/capture.md` and ADRs 0025–0027:
  * 0025: a probe on `Integration::Session#process`;
  * 0026: the `fixtures` snapshot;
  * 0027: redaction and capture fidelity.
* Specs committed red before the implementation (`dcdc24d`).
* Built:
  * the `doubletrack capture` command (`Capture::Runner`), with the probe, record
    builder and assembler behind it;
  * session `snapshot: "fixtures"` and `test_status`;
  * one template per snapshot kind;
  * capture fidelity in the CLI, `run.json` and the report;
  * per-repro snapshots;
  * `doubletrack/http_stubs.json`;
  * `make capture-shop`.
* shop gained fixtures, a fixture-backed test and `http_stubs.json`.
* The CI axe job now generates its report from hand-written plus stub-less captured
  sessions, so the fidelity mismatch table is checked too.

**Found along the way**:
* I changed the probe-loading design before the first run (`RUBYOPT` would have loaded
  it into the `bundle` CLI process).
* Two over-claims in my own specs and ADR, now fixed and tested: "every twin" was
  checked on one twin, and "both Rails versions" was not checked at all.

**Proven (locally)**:
* unit 287 examples; integration 60 examples, including `capture_spec.rb` (8);
* capture on shop: 7 sessions, 13 requests; replay fidelity 13/13;
* the negative control without stubs drops to 12/13 and names the request.
* CI [run 41717869635](https://github.com/JoshBlazer/doubletrack/actions/runs/41717869635): all 9 jobs ✓ (integration 60, unit 287 on Ruby 3.2–4.0,
  eval 13/13 repros, axe 5 pages including the fidelity table). **M5 marked done.**

**What's next: M6 (real-world demo)**
1. Pick an open-source Rails app with an upgrade PR (adjacent Rails versions, SQLite or
   easily switched, integration tests). Check the license and contact the maintainers
   before publishing (R9).
2. Dual-boot it, `capture`, `run`, and file any real findings upstream with their
   reproduction specs.
3. Publish the report to GitHub Pages and write the walkthrough.

M6 involves outward-facing actions (contacting maintainers, filing issues, publishing).
Those need the maintainer's go-ahead at each step.

**Open questions**
* Should capture also offer a Rack-middleware mode, for system tests? It's out of M5
  scope.
* Should `capture` merge with existing hand-written sessions or keep a separate file?
  It's separate (`captured.jsonl`) today.
* The earlier open questions are still open: `report` exit code, `accept --all`,
  sequence alignment.

**Blockers**: none.

---

## 2026-11-03: Session 6 (review and hardening of M0–M5, before M6)

Asked to refine everything before M6. Three independent read-only review passes (twin and
replay core; diff, report, specgen and capture; docs against the code) produced the list
below. Each code finding got a failing spec first (`test:` commit, red), then the fix.

**Fixed (code)**
* Generated specs: comment injection through finding titles (JSON keys from the app);
  assertions as strict as verification (`eql` / `Repro.same?`), so a `1` → `1.0`
  finding can't yield a "verified" spec that passes on the next Rails.
* CLI: `report` exits 1 on new findings; internal errors and corrupt `run.json` exit 2
  with a message; `--help` on every subcommand returns instead of calling `exit`;
  `init`/`doctor` no longer say "planned for M5".
* Twins: `DATABASE_URL` percent-encoded (checked against Rails 8.0 and 8.1's URL
  resolver, and with a real run under `/tmp/dt a#b%41`); protocol fds close-on-exec;
  no fd leak and a `TwinBootFailed` when spawn fails; `reply_to: null` errors shown as
  is; oversized frames name the twin and the twin exits instead of looping.
* Threads: `Coordinator.parallel_map` joins every twin's thread before re-raising
  (used by `run` and the reproduction generator).
* Traces: invalid UTF-8 scrubbed before sending; `1e400` kept serializable.
* Report: values shown as JSON; `(absent)` only for the missing side; shell-quoted
  copy/run commands; accepted findings' repros not re-rendered.
* Capture: RSpec example ids keep same-named examples apart; query kept for path-less
  URLs; secret keys redacted.
* Config validation; unique results directory per run; per-repro errors include
  non-Doubletrack exceptions instead of aborting the run; bounded log tail.

**Fixed (docs)**
* README demo now runs verbatim from the repo root (ran it: 1 new → repro passes on
  8.0, fails on 8.1 → `accept` into `tmp/` → 0 new, exit 0; fixture untouched).
* Install instructions say the gem isn't on rubygems.org yet (`github:` / `path:`).
* Over-claims removed: "real or synthesized traffic", "each backed by a minimal
  reproduction spec" (README, PRODUCT, gemspec).
* ARCHITECTURE finalized (no longer "draft"; template per snapshot kind; Gemfile
  statement scoped; formats list complete). PRODUCT, RISKS (`doctor` not built), ADR
  0004/0005 status, protocol/replay/recorder/specgen design notes, run.md `hit`, CI
  step names, CHANGELOG order, eval README, AI-assistance table (M4, M5, this pass).
* Walkthroughs m0–m4 marked as records of their milestone.
* New limitations stated: control A builds the snapshot (state only it has would be
  masked as noise), responses over ~48 MB, captured requests lose their host.

**Considered and left as is**
* `report` reuses the baseline path recorded in `run.json`; moving results to another
  checkout needs `--baseline` on a new `run`. Noted, not changed.
* The M4 walkthrough shows the author line from `git config`; left as recorded output.

**Proven (locally)**: lint clean; unit 320 examples (incl. eval specs); integration 60
examples, 0 failures. README demo run verbatim.

**CI**: [run 41733480715](https://github.com/JoshBlazer/doubletrack/actions/runs/41733480715), all 9 jobs ✓. Two earlier runs failed on Ruby 3.3
only, both in specs written this session, not in Doubletrack:
* the spawn-failure leak spec compared fd *counts*, which other specs' pipes being
  closed by GC can change. It now compares fd sets;
* `twin/fds_spec.rb` let two `IO` objects own the same fd numbers. GC later closed
  numbers that had been reused for another file (`EBADF` while loading openssl). The
  original pipe ends now have `autoclose = false`.

**Next**: M6, which needs the maintainer's go-ahead for each outward-facing step.

---

## 2026-11-04: Session 7 (report UI/UX pass)

Generated two reports (shop with captured + hand-written sessions; the planted app with
13 findings) and went through every page in Chrome at 1280 px.

**Found**
* Finding pages dumped whole JSON channels side by side with nothing marked. In the
  planted `sql_writes[*].binds.name` finding the only difference is a double space in
  "Ada  Lovelace", inside ~40 identical lines.
* The overview's biggest number was route coverage; the finding counts came second and
  the verdict didn't state them.
* Titles were raw paths only (`performed_jobs[*].mail[*].subject changed`).
* Section names "Sql writes", "Http"; "minimized from 1"; the gem line in the report
  wouldn't resolve before release; the accept command ignored a custom baseline.

**Changed** (specs first: `9174ab9` red, then the implementation)
* `Report::LineDiff` (LCS line diff, folding) and `Report::Describe` (plain names).
* Finding page: plain sentence under the title, `<del>`/`<ins>` with − / + markers,
  whitespace-only note, accurate repro wording, accept command with `--results` /
  `--baseline` when needed.
* Overview: counts in the verdict with a link; coverage moved among the other stats;
  top findings listed by description and route.
* Findings table: description + path, a Reproduction column (verified, not verified,
  error, not generated, accepted).
* CSS: diff colors with markers (never color alone), narrow-screen wrapping.

**Not verified visually**: the narrow-screen layout (the browser window couldn't be
resized from here); it relies on a CSS rule, not a screenshot.

**Proven**: lint clean; unit 341 examples; integration 60 examples. CI [run 41737386440](https://github.com/JoshBlazer/doubletrack/actions/runs/41737386440): all 9 jobs ✓, axe 0 violations on 5 pages (including a finding page with diff marks). axe runs
in CI.

---

## 2026-11-04: Session 8 (report visual redesign)

Feedback: the report "looks too basic". Redesigned the five page types; content and
semantics unchanged, so every existing spec about what the report says still holds.

* Palette chosen with the data-viz validator, not by eye (table in
  `docs/design/diff.md`): severity = red / orange / blue. The first dark-mode candidates
  failed the normal-vision floor (red vs orange ΔE < 15); a grid search found
  `#bd3138` / `#d9782e`, which pass every check.
* Components: app bar with logo and version chip, verdict banner, hero number +
  segmented bar + tiles, meter, finding rows, cards for twins, status icons, callouts,
  terminal blocks, pill filters. Dark theme; print and forced-colors rules.
* New specs: the severity bar's accessible name and zero parts, every SVG
  `aria-hidden`, dark/print/forced-colors rules present.
* Looked at both themes in Chrome (dark: the browser's own setting; light: a copy of
  the report with the dark block removed). axe covers the light theme in CI; the dark
  theme's contrast comes from the validator and the token choices, not from axe.

---

## 2026-11-05: Session 9 (M6: once-campfire)

* App: basecamp/once-campfire (MIT, SQLite), upgrade PR #423 (Rails main `e3d5c569` →
  `8b06b0eb`, lockfile only). The earlier upgrade commit was unusable: at Rails main
  `1a02651` with Minitest 6, `bin/rails test` loads no tests.
* Campfire exposed six Doubletrack bugs; each fixed with a failing spec first:
  Rails main revisions (`d9de98c`), capture error excerpt (`f4a7fcd`), Bundler re-exec
  (ADR 0028) and snapshot restore under app-held connections (ADR 0029) (`166fca5`),
  Minitest names (`8c76d8f`), side effects from app threads (ADR 0030, `b2ad604`), gzip
  bodies (`9ce0fc2`). Shop gained `PATCH /orders/:id/audit` for ADR 0030's spec.
* Result on Ruby 4.0.9: 22 findings, all one Rails change (`Vary` gains
  `X-Requested-With`, Rails `e38dd281d3`, GHSA-r9jg-fmfx-2gv6), all verified, the same
  on three seeds; all 22 generated tests pass on current and fail on next against
  Campfire itself. Details: `docs/walkthroughs/m6.md`.
* Machine: Ruby 4.0.9 installed with rbenv for Campfire's `.ruby-version`; libvips and
  ffmpeg installed by the maintainer.

**Outward-facing steps, each approved by the maintainer** (R9):
1. Commented on #423 about the `Vary` change: https://github.com/basecamp/once-campfire/pull/423#issuecomment-6667493665
2. Published the report to GitHub Pages: https://joshblazer.github.io/doubletrack/campfire-pr423/ (`gh-pages` branch, local paths
   replaced with `/app`).
3. Confirmed from Campfire's CI logs that it ran `0 runs` on the Rails `1a02651` +
   Minitest 6.0.6 commits (walkthrough §6) and commented on #287, where Minitest 6
   came in: https://github.com/basecamp/once-campfire/pull/287#issuecomment-6667886815

**Proven**: lint clean; unit 373 examples; integration 62 examples; eval PASS (13/13).

---

## 2026-11-05: Session 10 (README polish; M7: changes and likely causes)

* README rewritten around the Campfire result, with report screenshots; repository
  About (description, homepage, topics) set. Upstream: the note on once-campfire #287 was
  posted by the maintainer.
* Roadmap: M7–M12 added ("from demo to product"), in the order agreed with the maintainer:
  changes and causes, init/doctor + 0.1.0, GitHub Action, PostgreSQL, a Ruby per twin,
  capture fidelity and scale.
* M7 done: findings grouped into changes (ADR 0031); likely causes searched offline in the
  dependencies that changed (ADR 0032). Campfire: 22 findings → 1 change, likely cause Rails
  `e38dd281d3`. Shop: names `json`. Eval: 13 changes, none mixing two plants. Walkthrough:
  `docs/walkthroughs/m7.md`.

**Proven**: lint clean; unit 401 examples; integration 63 examples; eval PASS (13/13);
CI run 42110238868 (9/9).

**What's next**: M8, `doubletrack init` and `doctor`, and a releasable 0.1.0.
