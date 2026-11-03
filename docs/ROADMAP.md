# Roadmap

Each milestone ends with an **exit check** (commands that prove it), a walkthrough in
`docs/walkthroughs/mN.md`, and a green CI run. The core (M0–M4) must be finished before
any later layer starts.

| ID | Milestone | Exit check | Status |
|---|---|---|---|
| **M0** | Spike: twins talk. `shop` dual-boots two adjacent Rails versions; the coordinator spawns two twins, sends one request to each, and prints both responses. | `bin/doubletrack-spike fixtures/apps/shop` shows a response from each version, with versions reported in `hello` | see README status |
| M1 | Side-effect recorder: per-request traces with response, SQL writes, jobs, mail, cache, outbound HTTP. | An integration test asserts that a trace for a known request contains the expected side effects | not started |
| M2 | Session replay: snapshots, time freezing, seeding, HTTP interception, cookies across requests. | The same session replayed twice on the same version produces identical normalized traces | not started |
| M3 | Diff, denoise, cluster, report: three-way comparison and the static report (overview, findings, detail, coverage). | `doubletrack run` on `shop` produces a report; the planted-change fixture yields the expected findings and the clean fixture yields none | not started |
| M4 | Reproduction specs and baseline. | A generated spec passes on old and fails on new; `accept` suppresses the finding on the next run | not started |
| M5 | Test-derived traffic capture. | `doubletrack capture` on `shop` produces sessions from its request tests, and `run` uses them | not started |
| M6 | Real-world demo on an open-source Rails app with a recent or open upgrade PR; publish the report to Pages and write it up. | Published report URL + walkthrough + any upstream issues filed | not started |

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
