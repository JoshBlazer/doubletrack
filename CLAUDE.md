# CLAUDE.md: working on Doubletrack

Read this, `docs/PROGRESS.md` (resume from its latest "What's next"), and the current
milestone in `docs/ROADMAP.md` before doing anything.

## Ground rules

* **Never claim done without proof.** "Done" means a command proves it, and you show its
  output. The README status table names the proving command for every row; update it in
  the same commit as the work. A milestone isn't done until its exit check is green in CI.
* **Design before code for hard modules** (protocol, snapshots, noise mask, clustering,
  specgen, bisect): a note in `docs/design/` with signatures, and failing tests, *before*
  the implementation.
* **Every non-obvious choice is an ADR** in `docs/DECISIONS.md`. Every new runtime
  dependency needs an ADR. The gem has **one** runtime dependency, `nokogiri` (ADR 0017),
  and it's used in the coordinator only.
* **Honest limitations.** Never overclaim in docs, README, or commit messages.
* If a decision is irreversible or contradicts the brief, stop and ask the maintainer.
* Core (M0–M4) before any later layer (L1–L9).
* Boring, explicit code in the core; save metaprogramming for the CLI/config DSL.

## Hard constraints (summary)

Zero cost; static offline reports; nothing leaves the machine; no Postgres for
Doubletrack itself; AI optional and local only; never mutate the target app's code;
nothing escapes the sandbox (no mail delivery, no outbound HTTP, no real job queues).

## Environment

* Linux/macOS only (ADR 0003). On this machine: WSL Ubuntu, repo at `~/doubletrack`,
  Ruby via rbenv (`~/.rbenv`).
* Twin code (`lib/doubletrack/twin/`, `protocol*`, `errors.rb`) must use **only the
  standard library**: it runs inside the target app's bundle.

## Commands

| What | Command |
|---|---|
| Unit tests | `bundle exec rake spec` (or `make test`) |
| Lint | `bundle exec rake standard` (autofix: `bundle exec standardrb --fix`) |
| Install fixture bundles | `make fixtures` |
| Integration tests (boot real Rails twins) | `bundle exec rake spec:integration` |
| M0 exit check | `ruby bin/doubletrack-spike fixtures/apps/shop --path /orders` |
| Replay + diff + report on shop (M3) | `make run-shop` (or `bundle exec exe/doubletrack run fixtures/apps/shop`) |
| Precision/recall eval (M3), plus every repro run on both Rails versions (M4) | `make eval` (writes `eval/results/<date>.json`) |
| Repro specs + accept/baseline exit check (M4) | `bundle exec rspec spec/integration/repro_spec.rb` (after `make fixtures`) |
| Capture sessions from shop's tests, then replay them (M5) | `make capture-shop`, `bundle exec rspec spec/integration/capture_spec.rb` |
| Build gem | `gem build doubletrack.gemspec` |

## Conventions

* Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`), small and focused.
* RSpec; tests must not touch the network (`spec_helper` blocks TCP).
* Public API documented with YARD tags.
* At the end of every session, append to `docs/PROGRESS.md`: date, done, proven
  (commands + results), next, open questions, blockers.
