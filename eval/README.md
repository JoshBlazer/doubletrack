# Evaluation harness

`make eval` (`ruby eval/run.rb`) replays the two planted fixtures
(`fixtures/apps/planted/`, ADR 0020) and scores Doubletrack against their ground truth.
* **Recall**: the share of planted changes caught by at least one finding with the right
  route, path and severity.
* **Precision**: the share of findings explained by a plant.
* **Clean**: the number of findings on the app with no planted changes. It must be 0.
* **Repros confirmed** (M4): findings whose generated Minitest reproduction was verified
  during the run, then *actually run* under the app's own bundle, passing on the current
  Rails and failing on the next. All generated files run in one process per Gemfile.

It exits 1 if any plant is missed, any finding is unexpected, the clean app has a
finding, or any finding lacks a confirmed reproduction. CI runs it on every push (the `eval` job).

Each run writes `eval/results/<date>.json`, so the numbers are tracked over time:

| Date | Doubletrack | Rails | Plants caught | Precision | Recall | Clean findings | Noise filtered | Repros confirmed |
|---|---|---|---|---|---|---|---|---|
| 2026-11-03 | 0.0.1 (M3) | 8.0.5.1 → 8.1.4 | 9 / 9 | 1.00 | 1.00 | 0 | 2 (changes), 2 (clean) | – (not built) |
| 2026-11-03 | 0.0.1 (M4) | 8.0.5.1 → 8.1.4 | 9 / 9 | 1.00 | 1.00 | 0 | 2 (changes), 2 (clean) | 13 / 13 |

Both rows are from the same day, so `eval/results/2026-11-03.json` holds the M4 run (the
M3 file is in git history at `ecba16f`). M5 and the post-M5 review didn't change the
eval: CI's `eval` job reproduced the M4 numbers (13 / 13 repros) in
[run 41717869635](https://github.com/JoshBlazer/doubletrack/actions/runs/41717869635).

The first eval run had precision 0.92: one finding (`response.headers.date` added) had
no entry in `expected.yml`. The clean app, with the same Rails and the plant switched
off, has no such difference, so the plant `expires_in` (P9) caused it. The fix was to
the ground truth, not to Doubletrack. The full story is in `docs/walkthroughs/m3.md`.
