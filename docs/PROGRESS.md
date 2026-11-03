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
