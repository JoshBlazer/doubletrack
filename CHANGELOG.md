# Changelog

All notable user-visible changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - not yet published

The first release: capture, three-way replay, diff and noise mask, the static report,
verified reproductions, the baseline, changes with likely causes, `init` and `doctor`.

### Added
- PostgreSQL apps (M10, ADR 0037): each twin gets a private database on the app's test server; snapshots are template databases restored with `DROP … WITH (FORCE)` / `CREATE … TEMPLATE`; repros ship a recipe and rebuild the template; twins drop their databases at shutdown. `doctor` accepts PostgreSQL with the `pg` gem.
- GitHub Action (M9, ADR 0036): `uses: JoshBlazer/doubletrack` installs Doubletrack from the action's source, optionally captures, runs, writes the job summary, uploads the report artifact, keeps one PR comment up to date (`comment: "true"`), and fails according to `fail-on`.
- `summary.md` (M9): every run and report writes a GitHub-flavored Markdown summary next to `run.json`.
- `doubletrack init` (M8, ADR 0033): writes `Gemfile.next` for the next Rails (a copy of `Gemfile` with only the rails line changed, or a symlink when the Gemfile already branches on `next?`) and `Gemfile.next.lock`; `--install` runs `bundle install` for it. Never edits `Gemfile`.
- `doubletrack doctor` (M8, ADR 0034): checks platform, Ruby, dual boot, Rails versions, both bundles, the database, HTTP clients, sessions and git, then boots both versions; each problem comes with a fix. Exit 1 when a check fails.
- Release workflow (ADR 0035): a `v*` tag publishes to rubygems.org through trusted publishing. CI installs the built gem into an empty directory and runs it on shop.
- Changes (M7, ADR 0031): findings that are the same difference on different routes are grouped into one change with a stable `c-…` id and a summary (`adds X-Requested-With`). The report and CLI lead with changes; `doubletrack accept c-…` accepts a whole change. `findings.json` is now `findings_version` 2.
- Likely causes (M7, ADR 0032): each change names the dependency commit, changelog entry or source file that mentions its text, searched offline in the gems that differ between the two bundles (`run.json` `dependency_changes`). On once-campfire PR #423 it names Rails `e38dd281d3`.
- `make eval` checks that no change mixes findings of two planted differences.
- Gem skeleton and `doubletrack` CLI (`help`, `version`; other commands report the milestone that delivers them).
- Coordinator ↔ twin protocol (NDJSON on fds 3/4, schema_version 1) and twin process management with boot/request timeouts and crash detection.
- `bin/doubletrack-spike` (M0): boots an app on its current and next Rails versions and prints one response from each, with side-effect counts.
- Side-effect recorder (M1): every replayed request yields a trace with the response, SQL writes, enqueued jobs, delivered mail, cache writes/deletes, and outbound HTTP calls.
- Outbound `Net::HTTP` calls inside twins are answered from stubs or blocked with a synthetic 503; no socket is opened.

- Session replay (M2): sessions files (`sessions/*.jsonl`); per-session SQLite snapshot restore (`VACUUM INTO` template); time frozen per request at `started_at + offset_ms`; `rand` seeded per session; cookies carried across requests.
- Enqueued jobs are performed inline after each request, and their side effects recorded under `performed_jobs` (on by default; `perform_jobs: false` to disable).
- Traces record the route hit, the decoded session, and deprecation warnings.
- `Doubletrack::Normalize::Trace`: removes volatile values (request ids, runtimes, session ids, CSRF tokens, session-cookie ciphertext, backtraces).

- `doubletrack run [APP]`: replays every session on control A, control A′ and candidate B, then writes raw traces, `findings.json`, `run.json` and a static HTML report. Exit 0 means no findings, 1 means findings, 2 means error. `--seed` reproduces a run.
- `doubletrack report RESULTS_DIR`: regenerates findings and the report from stored traces.
- Normalizers for JSON (sorted keys), HTML (Nokogiri; attribute order, whitespace, CSRF tokens and nonces) and SQL (canonical text with literals moved out).
- Three-way noise mask, fingerprinting, clustering and severity (data-changing, user-visible, cosmetic). Cache writes count as data-changing.
- `doubletrack.yml` (optional): Gemfiles, sessions directory, seeds, `perform_jobs`, ignored columns and headers, timeouts.
- `make eval`: precision and recall on planted fixtures, with results in `eval/results/`.

- Reproduction specs (M4): `doubletrack run` builds one per new finding, checks it on the live twins (passes on the current Rails, fails on the next), drops earlier requests it doesn't need, and writes it as RSpec or Minitest (`repro_framework: auto|rspec|minitest`) under `results/<run_id>/repro/`, with a copy of the database snapshot. The report shows the spec, its verification and the commands to run it.
- `Doubletrack::Repro.replay`: the helper generated specs call. Add the gem to the app's test group to run them (until release: `gem "doubletrack", github: "JoshBlazer/doubletrack", require: false, group: :test`).
- `doubletrack accept ID --reason TEXT`: records a finding in `doubletrack.baseline.yml` (committed to the app). Later runs and reports mark it accepted; counts, the verdict and the exit code use new findings only. Stale entries are reported.
- `doubletrack run --baseline FILE --repro-framework NAME`; `doubletrack.yml` keys `baseline` and `repro_framework`.

- `doubletrack capture [APP] [--out FILE] [--command "SCRIPT ARGS"] [--gemfile FILE]` (M5): runs the app's tests on the current Rails with a probe on `ActionDispatch::Integration::Session#process`, and writes one session per request-making test to `doubletrack/sessions/captured.jsonl`. Requests that can't be replayed skip their test, with a reason; identical sessions are written once; values of secret-looking environment variables are redacted.
- Sessions can use `"snapshot": "fixtures"` (schema plus the app's test fixtures) and carry `test_status`; `doubletrack run` builds one template per snapshot kind and reports capture fidelity (replayed status vs. the test's) in the CLI, `run.json` and the report's coverage page.
- `doubletrack/http_stubs.json` (config key `http_stubs`): HTTP stubs added to captured sessions.

### Changed
- Report redesign: dark app bar, cards, a verdict banner with icon and call to action, a hero count of new findings with a severity bar and tiles, a coverage meter, finding rows, twin cards, status icons (verified / not verified / error), terminal-style command blocks, and a dark theme (`prefers-color-scheme`). Severity colors were validated for color-vision deficiency in both themes and always sit beside a text label.
- Report: changed lines are marked in the side-by-side sections (− control A, + candidate B, on red/green), and long unchanged stretches are folded. Before, whole JSON blobs were shown and the reader had to spot the difference.
- Report: every finding has a plain-language description ("Email: subject, in a job performed after the request changed") next to its technical path; the findings table shows whether each reproduction was verified.
- Report overview: the verdict states the new-finding counts and links to them; route coverage no longer outranks the findings.
- Report: section names "SQL writes", "Outbound HTTP", "Cache writes"; a note when a value differs only in whitespace; the accept command includes `--results`/`--baseline` when the run used non-default ones; tables fit narrow screens.
- Generated specs' `LoadError` hint and the report give the pre-release Gemfile line (`github: "JoshBlazer/doubletrack"`).
- `run.json`: `snapshot` became `snapshots` (one per kind). `repros.json`: each repro names its own `snapshot`.
- `findings.json` occurrences carry `segments` and `op`; `run.json` gains `baseline`, `counts.accepted` and `timings.repro_s`. CLI output says "N new" and lists accepted counts.
- Twins render production error pages (`consider_all_requests_local = false`) instead of Rails' debug page.
- First runtime dependency: `nokogiri` (HTML normalization, coordinator only).
- Protocol schema_version 2: `run_session` returns `traces` and accepts `http_stubs`.
- Protocol schema_version 3: `prepare_snapshot` implemented; `hello` reports routes and the session cookie name; traces are trace_version 2.
- Twins no longer load `db/schema.rb` at boot; their database is empty until a snapshot is restored.
- Twins use a fresh `:memory_store` cache and `show_exceptions = :rescuable`.

### Fixed
- Twins keep the user's own Bundler settings (`BUNDLE_WITH`, `BUNDLE_PATH`, `BUNDLE_DEPLOYMENT`, …), which `Bundler.with_unbundled_env` dropped; an optional bundler group needed for the app couldn't load (found in M10).
- Report: a Rails git revision keeps its case in table headers and eyebrows, which CSS uppercases (once-campfire's report showed `E3D5C569D2`).
- Gzip-encoded response bodies are compared by their decoded content; their bytes differed by the gzip header's timestamp, which the frozen clock doesn't reach (seen on once-campfire's cached pages).
- Side effects from the app's own threads (for example a push pool) are recorded under the trace's `background` and not diffed; before, they were attributed to whichever request was running and produced findings that didn't reproduce (ADR 0030).
- Snapshot restore copies the template into the live database through SQLite's backup API instead of deleting and copying the file, so connections the app holds itself (for example a WAL-checkpoint thread) stay consistent. On once-campfire this removed 25 false findings (`no such table`) out of 48 (ADR 0029).
- Apps whose lockfile was written by another Bundler version: `capture` loads its probe through `RUBYOPT` (it was lost when Bundler re-executed the test process, so nothing was captured), and twins keep their protocol pipes across that re-exec (ADR 0028).
- `capture`: when the app's tests crash while booting, the error now shows the exception message, not only the end of its backtrace.
- Apps that track Rails main: twins report the git revision of the Rails they loaded (`rails_revision`), the dual-boot check compares version and revision, and the report, CLI summary, baseline and reproduction specs name each side as e.g. `8.2.0.alpha (1a02651ac3)`. Before, two Rails main revisions both read `8.2.0.alpha` and `run` stopped with "dual boot not effective".
- Generated reproduction specs: a newline in a finding's title (which can come from a JSON key in the app's response) could end a comment and turn the rest of the line into code. Comment text is now escaped.
- Generated reproduction specs compare as strictly as the run verified them (`eql` in RSpec, `Doubletrack::Repro.same?` in Minitest). With `eq`/`assert_equal`, a `1` → `1.0` finding gave a "verified" spec that passed on the next Rails.
- `doubletrack report` exits 1 when there are new findings, like `run` (it always exited 0). `report --help` prints usage.
- Unexpected internal errors and corrupt results files exit 2 with a one-line message, never 1 (which means "new differences found").
- Twins work when the app or results path contains a space, `#` or `%` (`DATABASE_URL` is percent-encoded; with `#`, all three twins used to share one database file).
- Invalid UTF-8 in exception messages, SQL text, headers or cache keys no longer aborts the run; responses with numbers like `1e400` no longer crash the report.
- When one twin fails during a session or a reproduction, Doubletrack waits for the others before stopping them, so the error reported is the real one (not a protocol mismatch) and no thread backtraces are printed.
- Twin protocol pipes are close-on-exec, so a subprocess the app starts can't turn a twin crash into a 120 s timeout. A twin error without `reply_to` is shown as is; an oversized reply names the twin.
- The report shows values as JSON in "What changed" (`"1"` vs `1` is visible) and shows `(absent)` only on the missing side of an added or removed path, not for `null`.
- `report` no longer re-renders the reproduction of a finding accepted since the run.
- Capture: RSpec examples that share a description stay separate sessions; a URL with no path keeps its query; secret values used as parameter or header names are redacted too.
- `doubletrack.yml`: invalid timeouts and paths, dates and aliases are rejected with a ConfigError naming the file.
- Two runs with the same `--seed` in the same second get separate results directories.
- `init` and `doctor` no longer claim to be planned for M5; they are unscheduled.
