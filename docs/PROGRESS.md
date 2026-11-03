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
