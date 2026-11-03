# Evaluation harness

`make eval` (`ruby eval/run.rb`) replays the two planted fixtures
(`fixtures/apps/planted/`, ADR 0020) and scores Doubletrack against their ground truth.
* **Recall**: the share of planted changes caught by at least one finding with the right
  route, path and severity.
* **Precision**: the share of findings explained by a plant.
* **Clean**: the number of findings on the app with no planted changes. It must be 0.

It exits 1 if any plant is missed, any finding is unexpected, or the clean app has a
finding. CI runs it on every push (the `eval` job).

Each run writes `eval/results/<date>.json`, so the numbers are tracked over time:

| Date | Doubletrack | Rails | Plants caught | Precision | Recall | Clean findings | Noise filtered |
|---|---|---|---|---|---|---|---|
| 2026-11-03 | 0.0.1 (M3) | 8.0.5.1 → 8.1.4 | 9 / 9 | 1.00 | 1.00 | 0 | 2 (changes), 2 (clean) |

The first eval run had precision 0.92: one finding (`response.headers.date` added) had
no entry in `expected.yml`. The clean app, with the same Rails and the plant switched
off, has no such difference, so the plant `expires_in` (P9) caused it. The fix was to
the ground truth, not to Doubletrack. The full story is in `docs/walkthroughs/m3.md`.
