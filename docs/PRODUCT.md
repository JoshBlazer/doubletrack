# Doubletrack: product

> **Upgrade Rails with proof, not hope.**

## The problem

Rails upgrades are risky because teams lean on their test suites, and the apps that most
need upgrading usually have the weakest tests. A green suite on the new Rails version
says little about the behavior the suite never asserted: which rows get written, which
jobs get enqueued, which emails go out, what the JSON looks like byte for byte.

## The product

Doubletrack replays real or synthesized traffic against a Rails app running on the
**current** and the **next** Rails version side by side. It reports every behavioral
difference (HTTP responses, database writes, enqueued jobs, emails, cache writes,
outbound HTTP calls), each backed by a minimal reproduction spec.

It observes and reports. It doesn't change your code, send your email, call your
APIs, or send your data anywhere.

## Users

| User | Needs | Primary surface |
|---|---|---|
| Engineer doing the upgrade | What changed, why, and how to fix it | Finding detail, reproduction specs, bisect |
| Tech lead / CTO | Is it safe to ship? How much work remains? | Report overview (printable) |
| Upgrade consultancy / freelancer | Evidence to hand to clients | The whole report as an assessment |
| Open-source maintainer | Did this Rails release change our behavior? | GitHub Action + upstream-ready repros |
| Rails community | Which Rails changes break real apps? | Public atlas (later layer) |

## Surfaces

### CLI

```
doubletrack init        # detect Rails version, set up/verify dual boot via next_rails, write doubletrack.yml
doubletrack doctor      # verify both versions boot, report environment problems with fixes
doubletrack capture     # derive sessions from the app's request/integration tests (later: staging)
doubletrack run         # replay sessions on control A, control A′ (same version), candidate B
doubletrack report      # (re)generate the static HTML report from stored results
doubletrack accept ID   # mark a finding as expected; writes to the committed baseline file
doubletrack bisect ID   # find the Rails version, then commit, that introduced a finding
doubletrack defaults    # test each new framework default individually (later layer)
```

Exit codes: `0` no new differences, `1` new differences found, `2` Doubletrack error.
Every run records its seed, and `--seed` reproduces a run exactly.

### Static report

* **Overview:** verdict ("Ready to ship" / "Not ready to ship"), counts by severity,
  sessions replayed, noise filtered, and route coverage shown prominently.
* **Findings:** grouped by root cause; one change hitting 300 sessions is one finding
  with a count. Severity: `data-changing` > `user-visible` > `cosmetic`.
* **Finding detail:** old vs new side by side for each side-effect channel, session
  timeline, noise-baseline evidence, bisect result, related deprecations and framework
  defaults, a copyable reproduction spec, and a copyable `doubletrack accept` command.
* **Coverage**, later **Framework defaults** and **Performance**.
* Calm, flat design where color encodes only severity. WCAG 2.1 AA (axe in CI),
  printable, and works with JS disabled.

### Baseline file

`doubletrack.baseline.yml`, committed to the target repo: accepted finding fingerprints,
each with a reason and an author. Later runs report only new findings.

### Reproduction specs

For each confirmed finding, a minimal RSpec request spec (Minitest optional) in
`spec/doubletrack/` that passes on the old version and fails on the new one. It restores
the recorded database snapshot through a helper shipped with the gem.

### GitHub Action (later layer)

Runs on PRs that change the Rails version: summary comment, check run, report artifact
(optionally Pages), and SARIF.

## Constraints we promise

1. Zero cost: GitHub Actions/Pages, RubyGems, and local tools only.
2. Static, offline reports.
3. Private by default: no telemetry, no accounts, no data leaves the machine.
4. No Postgres dependency for Doubletrack itself; the MVP observes SQLite apps.
5. AI is optional, local (Ollama), and never on the critical path.
6. A Ruby gem under the MIT license. Ruby 3.2+, Rails 7.1 → current (ADR 0008).
7. Never mutates the user's app code in the MVP.
8. Nothing escapes the sandbox: no email delivery, no outbound HTTP, no real job queues.

## Non-goals (MVP)

* Not an automatic upgrader.
* No hosted service.
* No browser/JavaScript behavior (system tests with real browsers).
* No live production traffic tapping (staging capture comes later, with scrubbing).
