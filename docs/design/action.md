# Design note: the GitHub Action (M9)

Status: **accepted for M9**. Related: ADR 0036 (a composite action that runs the gem from
its own source), ADR 0024 (exit codes and the baseline), ROADMAP layer L4.

## Goal

Every Rails-bump PR (from Dependabot, Renovate or a person) gets a behavior diff without
anyone running anything: a Markdown summary in the job summary (and, if asked, as a PR
comment), the full report as an artifact, and a status that can gate the merge. On M6 that
summary was written by hand on once-campfire #423.

**Exit check** (ROADMAP): a CI job runs the action (`uses: ./`) on shop. Its outputs say
`not_ready`, 1 change and 1 finding. Its summary names the change, its likely cause and
the verdict, and a script checks the summary against `findings.json` and `run.json`.

## Markdown summary (`results/<run_id>/summary.md`)

Written by `run` and `report` next to `run.json` (`Report::Markdown`). It's meant for PR
comments and job summaries, so it's GitHub-flavored, under 60,000 characters (GitHub's
limit is 65,536), and readable without the report:

```markdown
<!-- doubletrack-summary -->
### Doubletrack: Rails 8.0.5.1 → 8.1.4: ❌ Not ready to ship

**1 new finding in 1 change** (data-changing 0, user-visible 1, cosmetic 0) · 14 requests in 5 sessions · route coverage 7 of 8 (88%) · 0 noisy differences filtered

| Severity | Change | Where | Reproduced | Likely cause |
|---|---|---|---|---|
| user-visible | `exception.message`: "unexpected token at ''" → "unexpected end of … | `GET /orders/:id(.:format)` | 1/1 | json `ext/json/ext/parser/parser.c` (source file) |

<details><summary>16 bundle changes</summary> … </details>

If a change is expected: `doubletrack accept c-8a5d176afec2 --reason "..."` (commits
`doubletrack.baseline.yml`).

<sub>Doubletrack 0.1.0 · run 20261105T211356Z-42 · seed 42 · the full report is in this run's artifacts</sub>
```

* At most 25 changes in the table; the rest are counted.
* Cell text is escaped: `|` becomes `\|`, newlines become spaces, and values over 60
  characters are cut with `…`.
* A run with no new findings says ✅ Ready to ship, and lists accepted changes as a count.

```ruby
module Doubletrack::Report
  module Markdown
    MARKER = "<!-- doubletrack-summary -->"
    # @return [String]
    def self.call(run:, findings:, changes:, repros: {}) = ...
  end
end
```

## The action (`action.yml`, ADR 0036)

A composite action at the repository root:

```yaml
- uses: JoshBlazer/doubletrack@v0
  with:
    app-path: .                # the Rails app
    capture: "true"            # derive sessions from the tests first
    seed: "1"
    fail-on: user-visible      # data-changing | user-visible | any | never
    comment: "false"           # post/update one PR comment (needs pull-requests: write)
    github-token: ${{ github.token }}
```

Steps:
1. Install Doubletrack from the action's own checkout (`gem build` + `gem install` from
   `github.action_path`), so the action and the gem are always the same version.
2. `bundle install` for `Gemfile` and `Gemfile.next` (the app's Ruby must already be set
   up, for example with `ruby/setup-ruby`).
3. `doubletrack capture` when `capture` is `true`.
4. `doubletrack run --seed <seed> --out $RUNNER_TEMP/doubletrack`; the exit code is kept.
   An exit code of 2 (Doubletrack failed) fails the step at once.
5. Append `summary.md` to `$GITHUB_STEP_SUMMARY`; set the outputs `verdict`, `findings`,
   `changes`, `results-dir` and `summary-path`.
6. Upload `results-dir` (report, findings, repros, run.json; not the raw traces) as the
   artifact `doubletrack-report`.
7. With `comment: true` on a pull request: update the PR comment that starts with the
   marker, or create it (`gh api`). Never more than one comment per PR.
8. Fail according to `fail-on`: `data-changing` fails on any new data-changing finding,
   `user-visible` when the verdict is not ready (data-changing or user-visible), `any` on
   any new finding, and `never` only when Doubletrack itself failed.

Privacy: the summary and report stay inside the user's own GitHub (job summary,
artifacts, optional comment). Nothing goes anywhere else.

## Limitations

* The action needs the app's Ruby and system libraries installed by earlier steps; it
  doesn't guess them.
* Artifacts follow the repository's retention settings.
* A PR comment needs `pull-requests: write`. Workflows triggered from forks get a read-only
  token, so for them the comment step is skipped and the summary is still in the job.
