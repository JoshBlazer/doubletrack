# Roadmap

Each milestone ends with an **exit check** (commands that prove it), a walkthrough in
`docs/walkthroughs/mN.md`, and a green CI run. The core (M0–M4) must be finished before
any later layer starts.

| ID | Milestone | Exit check | Status |
|---|---|---|---|
| **M0** | Spike: twins talk. `shop` dual-boots two adjacent Rails versions; the coordinator spawns two twins, sends one request to each, and prints both responses. | `bin/doubletrack-spike fixtures/apps/shop` shows a response from each version, with versions reported in `hello` | **done** 2026-11-03, CI [run 41553435904](https://github.com/JoshBlazer/doubletrack/actions/runs/41553435904) |
| M1 | Side-effect recorder: per-request traces with response, SQL writes, jobs, mail, cache, outbound HTTP. | An integration test asserts that a trace for a known request contains the expected side effects | **done** 2026-11-03, CI [run 41556339580](https://github.com/JoshBlazer/doubletrack/actions/runs/41556339580) |
| M2 | Session replay: snapshots, time freezing, seeding, HTTP interception, cookies across requests. | The same session replayed twice on the same version produces identical normalized traces | **done** 2026-11-03, CI [run 41592499206](https://github.com/JoshBlazer/doubletrack/actions/runs/41592499206) |
| M3 | Diff, denoise, cluster, report: three-way comparison and the static report (overview, findings, detail, coverage). | `doubletrack run` on `shop` produces a report; the planted-change fixture yields the expected findings and the clean fixture yields none | **done** 2026-11-03, CI [run 41595451702](https://github.com/JoshBlazer/doubletrack/actions/runs/41595451702) |
| M4 | Reproduction specs and baseline. | A generated spec passes on old and fails on new; `accept` suppresses the finding on the next run | **done** 2026-11-03, CI [run 41714163293](https://github.com/JoshBlazer/doubletrack/actions/runs/41714163293) |
| M5 | Test-derived traffic capture. | `doubletrack capture` on `shop` produces sessions from its request tests, and `run` uses them | **done** 2026-11-03, CI [run 41717869635](https://github.com/JoshBlazer/doubletrack/actions/runs/41717869635) |
| M6 | Real-world demo on an open-source Rails app with a recent or open upgrade PR; publish the report to Pages and write it up. | Published report URL + walkthrough + any upstream issues filed | ✅ [report](https://joshblazer.github.io/doubletrack/campfire-pr423/), [walkthrough](walkthroughs/m6.md), [comment on once-campfire #423](https://github.com/basecamp/once-campfire/pull/423#issuecomment-6667493665) |

## From demo to product (M7–M12)

Planned 2026-11-05 after M6, in this order. Each keeps the same rules: design note and
failing specs first, an exit check proven in CI, a walkthrough.

| ID | Milestone | Exit check | Status |
|---|---|---|---|
| M7 | Changes and likely causes: group findings that are one change across routes; name the dependency commit, changelog entry or source that likely caused each, offline. | Campfire's 22 `Vary` findings are 1 change naming Rails `e38dd281d3`; shop's change names `json`; `accept c-…` accepts a whole change | **done** 2026-11-05, CI [run 42110238868](https://github.com/JoshBlazer/doubletrack/actions/runs/42110238868), [walkthrough](walkthroughs/m7.md) |
| M8 | `doubletrack init` and `doctor`, and a releasable 0.1.0 (release workflow; publishing itself is the maintainer's step). | `init` dual-boots a fresh Rails app for the next version; `doctor` explains a broken setup; `gem build` + install + `doubletrack run` from the installed gem | in progress |
| M9 | GitHub Action for Rails-bump PRs: run, upload the report, write a Markdown summary. | The action runs on a fixture PR in CI and its summary matches the report | planned |
| M10 | PostgreSQL apps. | shop on PostgreSQL: replay determinism and the M3/M4 exit checks pass in CI against a Postgres service | planned |
| M11 | A Ruby per twin (`.ruby-version` per Gemfile). | candidate B on a different Ruby than control A, in CI | planned |
| M12 | Capture fidelity and scale: uploads, raw bodies, hosts; sessions in parallel. | shop capture fidelity 100% including uploads; a parallel run gives the same finding ids as a serial one | planned |

## Later layers (priority order)

| ID | Layer |
|---|---|
| L1 | Bisect: Rails version, then commit, that introduced a finding |
| L2 | Framework defaults explorer |
| L3 | Route-aware fuzzing |
| L4 | GitHub Action + SARIF |
| L5 | Precision/recall dashboard on Pages |
| L6 | Performance diffs (query counts, allocations, latency with confidence ranges) |
| L7 | Nightly public atlas across open-source Rails apps |
| L8 | Ruby version and major gem upgrades (Devise, Sidekiq) |
| L9 | Optional local-AI explanations (Ollama) |

## v0.1 evaluation target

Every planted data-changing difference in `fixtures/apps/planted/` is caught, and the
clean app yields zero findings (`make eval`).
