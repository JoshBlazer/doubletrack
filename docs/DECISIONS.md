# Architecture decision records

Format: each ADR has a status (`proposed`, `accepted`, `superseded by NNNN`), context,
decision, and consequences. ADRs are append-only: to change a decision, write a new ADR
that supersedes the old one.

---

## ADR 0001: Dual boot via `next_rails`

**Status:** accepted (2026-11-03)

**Context.** We must run one app on two Rails versions. Options: (a) two checkouts of the
app with different lockfiles; (b) a single checkout with two Gemfiles/lockfiles, the
convention popularized by `next_rails` (`Gemfile` + `Gemfile.next` →
`Gemfile.next.lock`, switched by `BUNDLE_GEMFILE`); (c) generating a temporary Gemfile
per run.

**Decision.** Use the `next_rails` convention. The `Gemfile` defines `next?` (true when
`BUNDLE_GEMFILE` ends in `Gemfile.next`) and branches on it. `Gemfile.next` is a symlink
to `Gemfile`. `doubletrack init` will detect or set this up (in M0 the fixture app has it
by hand).

**Consequences.** + It's what upgrade teams already use, so there's nothing new to learn.
+ One working tree means both twins run byte-identical app code. − It needs a
symlink, which is fine on POSIX (ADR 0003). − Apps using a different dual-boot scheme
(e.g. `bootboot`) need an adapter later.

---

## ADR 0002: One OS process per twin

**Status:** accepted (2026-11-03)

**Context.** Two Rails versions can't be loaded into one Ruby VM: constants, gem
activation and `require` caches are global.

**Decision.** Every twin (control A, control A′, candidate B) is a separate process,
spawned by the coordinator inside `Bundler.with_unbundled_env` with an explicit
`BUNDLE_GEMFILE`, and with `RUBYOPT`/`RUBYLIB` removed. Twins boot once and are reused
across sessions.

**Consequences.** + Full isolation, and a crash in a twin is just a failed message. −
Boot cost ×3 (amortized across sessions). − We need an IPC protocol (ADR 0003).

---

## ADR 0003: Dedicated protocol file descriptors, NDJSON framing, POSIX only

**Status:** accepted (2026-11-03)

**Context.** Target apps write to stdout/stderr at boot and per request. Using stdout for
IPC is fragile: one `puts` in an initializer corrupts the stream.

**Decision.** Coordinator → twin on fd 3, twin → coordinator on fd 4. These are
anonymous pipes mapped at `Process.spawn`. Messages are newline-delimited JSON with a
versioned envelope. The twin redirects fds 1/2 to a log file before loading the app.
Full spec: `docs/design/protocol.md`.

Mapping fds above 2 into a child isn't supported by Ruby's `spawn` on Windows, so
**Doubletrack supports Linux and macOS; Windows users run it under WSL.**

**Consequences.** + App output can't corrupt the protocol, and it's captured in a log we
can show on failure. − No native Windows support. That's acceptable: Rails production
and CI are overwhelmingly Linux.

---

## ADR 0004: SQLite snapshots, not transaction rollback, for session isolation

**Status:** accepted (2026-11-03). Implemented in M2.

**Context.** Each session must start from the same database state on every twin. The
usual test-suite trick, wrapping each test in a transaction and rolling back, changes
behavior: `after_commit` callbacks never fire, and many apps enqueue jobs and send mail
from `after_commit`. That would hide exactly the data-changing differences we exist to
find.

**Decision.** Build a template snapshot once with `VACUUM INTO` (or the SQLite online
backup API). Naive file copies are unsafe in WAL mode. Before each session, copy the
template into the twin's private working database file and reconnect ActiveRecord.
Sessions really commit.

**Consequences.** + Commit callbacks behave as in production. − A file copy per session,
O(database size); large databases need a smarter strategy later (RISKS: snapshot cost).
− SQLite only in the MVP; other adapters need their own snapshot drivers.

---

## ADR 0005: Three-way noise cancellation (A, A′, B)

**Status:** accepted (2026-11-03). Implemented in M3.

**Context.** Two runs of the same app on the same version still differ: random tokens,
`SecureRandom` IDs, ordering of unordered queries, timestamps we fail to freeze. If we
compared only A vs B, every one of those would be reported as an upgrade finding.

**Decision.** Run two controls on the old version (A and A′) and one candidate (B). Any
field path that differs between A and A′ is noise and becomes a mask; only A-vs-B
differences outside the mask are reported. The mask can be strengthened by repeating
the controls. The report states how much was filtered.

**Consequences.** + Noise handling is empirical and self-calibrating, with no
hand-maintained ignore lists for most noise. − 1.5× the replay cost of a plain diff.
− A difference that only appears on B *and* is masked by coincidental A/A′ noise at the
same path is suppressed. The report must surface masked paths so this is visible
(RISKS).

---

## ADR 0006: Static-first report

**Status:** accepted (2026-11-03)

**Context.** Hard constraints: zero cost, private by default, fully offline.

**Decision.** The report is a directory of static HTML + CSS with a small amount of
vanilla JS for filtering. All assets are inlined or copied locally; no CDN, no web fonts,
no network calls. It must be readable with JS disabled and printable to PDF.

**Consequences.** + It can be emailed, attached to a PR artifact, or put on GitHub Pages.
+ There's no server to secure. − No interactive querying beyond client-side filtering.

---

## ADR 0007: RSpec for the gem's own tests

**Status:** accepted (2026-11-03)

**Context.** The brief specifies RSpec. Generated reproduction specs are also RSpec by
default.

**Decision.** RSpec 3 for the gem. Property-based tests use a small in-repo generator
helper first; adopting a property-testing gem (e.g. `rantly`/`prop_check`) would be a
dev dependency and gets its own ADR when needed. The fixture apps keep their own default
test framework (Minitest), since M5 must capture traffic from whatever the target app
uses.

**Consequences.** + It matches the reproduction-spec output, so we dogfood it.

---

## ADR 0008: Supported Ruby and Rails bounds

**Status:** accepted (2026-11-03)

**Context.** The brief: Ruby 3.2+, Rails 7.1 through the current release, comparing two
adjacent minor versions. As of 2026-11-03, the latest Rails is **8.1.4** and the latest
Ruby is **4.0.9** (from rubygems.org and ruby-build definitions).

**Decision.**
* **Coordinator (the gem itself):** Ruby `>= 3.2`, tested on 3.2, 3.3, 3.4 and 4.0.
* **Supported upgrade pairs (old → new):** 7.1 → 7.2, 7.2 → 8.0, 8.0 → 8.1. Each pair is
  a CI matrix entry once fixtures for it exist. M0 proves **8.0 → 8.1**.
* **Twins** run the app's Ruby. In the MVP that's the same Ruby binary as the
  coordinator (`RbConfig.ruby`); a per-app Ruby (via `.ruby-version`) is future work.
* Ruby 3.2's upstream maintenance has ended or is ending (check ruby-lang.org for exact
  dates). We keep it because the apps that most need upgrading run older Rubies. We'll
  drop it when CI can no longer install it.

**Consequences.** CI matrix = Ruby versions × Rails pairs, pruned to combinations Rails
itself supports (e.g. Rails 7.1 isn't tested on Ruby 4.0).

---

## ADR 0009: Twins run a `doubletrack` Rails environment overlaid without touching app code

**Status:** accepted (2026-11-03)

**Context.** The brief asks for a dedicated `doubletrack` environment derived from
`test`, and hard constraint 7 forbids mutating the user's app code.

**Decision.** The twin sets `RAILS_ENV=doubletrack`, requires the app's
`config/application.rb`, and then adds Doubletrack's own environments directory to
`Rails.application.paths["config/environments"]` before `initialize!`. Doubletrack's
`doubletrack.rb` environment file loads the app's `config/environments/test.rb` (if
present) and then applies Doubletrack overrides (mail `:test`, jobs `:test`, no eager
load, no asset compilation, a fixed `secret_key_base`). The database comes from
`DATABASE_URL` pointing at the twin's private SQLite file, so the app's `database.yml`
needs no `doubletrack:` entry.

**Consequences.** + No files are added to the target app. − It relies on Rails' `paths`
API (stable since Rails 3) and on `DATABASE_URL` merging. Both are covered by the
integration tests on each Rails pair. − Code that branches on `Rails.env.test?` sees
`false`; record any surprises in RISKS.

---

## ADR 0010: Sole commit authorship; AI assistance disclosed in the README

**Status:** accepted (2026-11-03)

**Decision.** Every commit is authored by the maintainer (JoshBlazer) alone. No
`Co-Authored-By` trailers and no added collaborators, for AI assistants or anyone
else, unless the maintainer explicitly asks. AI assistance is disclosed once,
in the README's "AI assistance" section, which also lists which modules started from
hand-written design notes and tests.

---

## ADR 0011: Twins use a fresh `:memory_store` cache, cleared per session

**Status:** accepted (2026-11-03)

**Context.** Rails' generated `test.rb` uses `:null_store`, so cache writes vanish and
an app's caching behavior (what it stores, under which key) is invisible. Cache contents
also carry state across sessions, which would break isolation.

**Decision.** The `doubletrack` environment overlay sets
`config.cache_store = :memory_store`, whatever the app's `test.rb` says. Each twin calls
`Rails.cache.clear` at the start of every session. Writes and deletes are recorded from
`cache_*.active_support` events, and written values are read back after the request.

**Consequences.** + Cache writes become observable and sessions start from an empty
cache. − Apps whose behavior depends on a specific store (Redis-only features, Solid
Cache SQL) behave as with a memory store. − With a working cache, a second request can
take a cached path the app's own test suite never exercised. That's realistic production
behavior, so we accept it.

---

## ADR 0012: Minimal `Net::HTTP` interceptor instead of WebMock

**Status:** accepted (2026-11-03)

**Context.** Outbound HTTP must be recorded and must never reach the network (hard
constraint 8). Options: (a) WebMock, mature and covering many libraries, but it has to be
in the *target app's* bundle, which we must not modify (constraint 7), and it adds a
dependency; (b) a small interceptor prepended to `Net::HTTP`, standard library only.

**Decision.** (b). The twin prepends a module to `Net::HTTP` **before the app boots**:
`connect` becomes a no-op (no socket is ever opened) and `request` returns either a
matching stub from the session payload (`http_stubs`) or a synthetic
`503 Service Unavailable` with `x-doubletrack: blocked`. Every call is recorded in the
trace. Calls outside a request (e.g. at boot) are blocked the same way and logged to the
twin log.

**Consequences.** + No dependency, nothing added to the app, and it covers everything
built on `Net::HTTP` (`Net::HTTP.get`, Faraday's default adapter, HTTParty, `open-uri`,
ActiveResource). − Libraries that bypass `Net::HTTP` (`httpx`, `curb`/`typhoeus`, raw
`TCPSocket`) are **not** covered (RISKS R6). Planned mitigation: `doctor` detects them
in the bundle, and a socket-level guard that fails closed comes later. − Stubs are
replayed only when supplied. Recording real responses into sessions comes with capture
(M5).

---

## ADR 0013: Protocol schema_version 2: `run_session` returns traces

**Status:** accepted (2026-11-03)

**Decision.** The `run_session` result payload changes from `responses[]` to `traces[]`
(`docs/formats/trace.md`), and the request payload gains an optional `http_stubs[]`.
That's an incompatible change, so `SCHEMA_VERSION` becomes 2. Coordinator and twins
always ship in the same gem, so a mismatch can only come from a stale process. It's
rejected at `hello`, as designed.

---

## ADR 0014: Perform enqueued jobs inline after each request (on by default)

**Status:** accepted (2026-11-03)

**Context.** Through M1, jobs were captured with the `:test` adapter but never run. The
brief calls inline performance "a later option". But many apps do their important work
in jobs: confirmation mail, webhooks, counters, search indexing. `shop` sends its order
confirmation from a job, so Doubletrack saw the job enqueued but never the email. A
Rails upgrade that changes what a job *does* (serialization of its arguments, mailer
rendering, `after_commit` ordering inside the job) would be invisible. The maintainer's
guidance was to do what's best for customers.

**Decision.** After every request, the recorder performs each job that request enqueued,
in enqueue order, from its serialized form (`ActiveJob::Base.execute(job.serialize)`).
Jobs enqueued by those jobs are performed too, up to 25 per request. Each job runs with
the clock frozen at the request's time, or at its `scheduled_at` if that's later. Its
side effects are recorded in a separate `performed_jobs[]` section of the trace, so the
request's own channels are unchanged. Exceptions raised by a job are recorded, not
raised. **On by default**; `perform_jobs: false` in `doubletrack.yml` turns it off.

**Consequences.** + Mail, writes and HTTP calls made by jobs are compared and reported
(they count as data-changing). + Still sandboxed: no real queue is touched, mail goes
to `:test`, and outbound HTTP is stubbed or blocked (hard constraint 8). − Replay is
slower for job-heavy apps. − Jobs run right after the request that enqueued them,
unlike production's concurrency, so a job that depends on running *after* later
requests can behave differently. − `retry_on` re-enqueues failing jobs, which can use
up the 25-job budget. Truncation is marked in the trace (`performed_jobs_truncated:
true`).

---

## ADR 0015: Doubletrack's own clock; `SecureRandom` left to the noise canceller

**Status:** accepted (2026-11-03)

**Context.** Time has to be frozen per request. The obvious tool is
`ActiveSupport::Testing::TimeHelpers#travel_to`. But A/A′ and B run *different*
ActiveSupport versions, so its implementation (sub-second truncation, which methods it
stubs, how it nests) could itself differ between twins and show up as a false finding.

**Decision.** The twin installs `Doubletrack::Twin::Clock`, a small standard-library
module prepended to the singleton classes of `Time`, `Date` and `DateTime`, so the same
code runs in every twin. Inside `Clock.freeze_at(t)`, `Time.now`, argument-less
`Time.new`, `Date.today` and `DateTime.now` return `t` exactly (no truncation).
Monotonic clocks are not touched. `SecureRandom` is **not** made deterministic.
Patching it works differently across Ruby versions, and it would weaken a library that
apps may use for real cryptography even in tests. Its values are dropped by the
normalizer where we know them (session IDs, CSRF tokens, request IDs). Anything else
is absorbed by the A/A′ noise mask (ADR 0005). We'll revisit an optional deterministic
mode if the eval shows masked findings (RISKS R11).

**Consequences.** + Same clock semantics on every Rails version. + No dependency on
test-only Rails APIs. − Time read by C extensions or by SQLite (`CURRENT_TIMESTAMP`) is
not frozen. The noise mask absorbs it.

---

## ADR 0016: Protocol schema_version 3: snapshots, determinism inputs, trace_version 2

**Status:** accepted (2026-11-03)

**Decision.**
* `prepare_snapshot` is implemented.
* `run_session` sessions carry `snapshot`, `started_at`, `seed` and per-request
  `offset_ms`. The payload gains `options.perform_jobs`.
* `hello` reports `routes[]` and `session_cookie`.
* Traces become trace_version 2, adding `route`, `time`, `session`, `deprecations` and
  `performed_jobs`.
* Twins no longer load `db/schema.rb` at boot. Their databases stay empty until a
  snapshot is restored.

These changes are incompatible, so `SCHEMA_VERSION` becomes 3. Details are in
`docs/design/replay.md`.

---

## ADR 0017: Nokogiri as the first runtime dependency (HTML normalization)

**Status:** accepted (2026-11-03)

**Context.** The brief requires HTML to be normalized with attributes sorted, whitespace
canonicalized, and CSRF tokens and nonces stripped, and it names Nokogiri. The standard
library has no HTML5 parser (REXML is XML-only and no longer a default gem). We could
normalize inside the twins, where Rails always brings Nokogiri. But A and B can bundle
*different* Nokogiri versions, and then a parser change would show up as an upgrade
finding.

**Decision.** HTML normalization runs in the coordinator. The gem declares
`nokogiri >= 1.13, < 2` as its only runtime dependency. Every Rails app already has
Nokogiri installed (via `rails-html-sanitizer`), so this adds nothing new in practice,
and precompiled native gems exist for common platforms. Twin code still uses only the
standard library.

**Consequences.** + One parser for all three twins, so normalization can't differ
between them. − It's a native-extension dependency for the gem itself. − The gem is no
longer dependency-free (the README and gemspec say so).

---

## ADR 0018: Severity rules, with cache writes counted as data-changing

**Status:** accepted (2026-11-03)

**Context.** The brief's rules are:
* DB writes, jobs, mail or outbound HTTP → `data-changing`;
* status, redirect, content type or a semantic body change → `user-visible`;
* everything else → `cosmetic`.

Cache writes aren't listed, so they would fall into `cosmetic`. Three other cases also
need a decision: rendered SQL text that changes while the written values don't (Rails
upgrades often re-quote or reorder SQL), the session cookie's contents, and exceptions.

**Decision.** One module (`Doubletrack::Diff::Severity`) with exhaustive tests:
* **Cache writes are `data-changing`.** A cached value outlives the request and is
  served to later requests.
* Jobs performed inline (ADR 0014) are `data-changing` on every channel.
* SQL: a change in binds, inline literals, statement, table or the number of writes is
  `data-changing`. A change **only** in canonical SQL text is `cosmetic`, because it says
  how the write is phrased, not what is written.
* The session contents, response cookies (`set_cookies`), and exceptions appearing,
  disappearing or changing class/message are `user-visible`.

**Consequences.** + Severity matches the impact on data and users rather than the
channel name alone. − It deviates from the brief's literal list for cache writes; this
ADR records that. − Inline literals are parsed by a regex-based SQL canonicalizer.
Unusual SQL may put a value change into `sql`, which would then be marked `cosmetic`.
The normalizer's property tests cover strings, numbers, `NULL` and booleans.

---

## ADR 0019: Noise mask on concrete paths per route; fingerprint on generalized paths

**Status:** accepted (2026-11-03)

**Context.** The noise mask must suppress real noise without hiding real changes (RISKS
R11). Clustering must merge one root cause seen across many sessions into a single
finding.

**Decision.**
* **Mask**: keyed by `(route, concrete path)`, unioned across sessions. Indices are kept,
  and prefixes apply in one direction only (noise at `a.b` masks `a.b.c`, never `a`).
  Masked paths and counts are always shown in the report.
* **Fingerprint**: `[channel, route, generalized path (indices → [*]), op, value shape]`.
  The shape is the pair of JSON types, except at enumerated leaves (status, exception
  class, statement, table, job class, queue, mailer, HTTP method, cache op, content
  type), where the values themselves are used. Example: "status 200 → 500" and
  "200 → 404" on the same route are different findings, but "total_cents 1999 → 2000"
  and "500 → 501" are one finding.
* The finding id is the fingerprint (`f-` + 12 hex chars), so it's stable across runs and
  usable by `accept` (M4).

**Consequences.** + Noise in one element doesn't hide changes in its siblings. + Stable
ids. − Index-based array diffs mean an extra write early in a request shifts later
paths, which can produce several findings for one cause. The report groups findings by
route, and sequence alignment is future work. − A route-level finding isn't merged
across routes. A framework change that affects every JSON endpoint produces one
finding per route.

---

## ADR 0020: Planted-change fixtures simulate upgrade behavior with version-gated code

**Status:** accepted (2026-11-03)

**Context.** The eval needs apps whose behavior changes between the two Rails versions
in *known* ways, plus an app that doesn't change at all. Relying on real Rails changes
would make the expected set depend on which Rails releases happen to be compared, and we
couldn't plant one change per channel.

**Decision.** `fixtures/apps/planted/{changes,clean}` are one app, dual-booted on Rails
8.0/8.1. `changes` enables `Planted.on?` (true only under Rails ≥ 8.1) at a handful of
points, one per channel and severity. `clean` has the identical code with the flag off.
Both contain noise (a `SecureRandom` token in a response) and an irrelevant HTML change
(attribute order and whitespace), and neither of those may become a finding. The
expected findings live in `changes/doubletrack/expected.yml`.

**Consequences.** + Deterministic ground truth for precision and recall, with one plant
per channel. − A plant is app code branching on the Rails version, not a real Rails
change. Real Rails differences are measured separately on `shop` and, in M6, on a real
app. − If Rails 8.0 → 8.1 itself changes something the base app touches, the clean
app's expected set is no longer zero. That would be a real finding, and we'd treat it
as one.

---

## ADR 0021: Twins render production error pages (`consider_all_requests_local = false`)

**Status:** accepted (2026-11-03)

**Context.** The first `doubletrack run` on `shop` reported 24 findings. Twenty-three of
them were inside one HTML page: Rails' **debug exception page**, which the twins
rendered for a 404 because the app's `test.rb` sets
`consider_all_requests_local = true`. That page is developer tooling, not app behavior.
It changes with every Rails release, and it embeds per-process object ids, which caused
156 A/A′ noise paths.

**Decision.** The `doubletrack` environment overlay sets
`config.consider_all_requests_local = false`. Rescuable exceptions (`show_exceptions =
:rescuable`) then render the app's production error pages (`public/404.html`, or
`config.exceptions_app`), as users would see them. Unrescued exceptions are still
recorded in the trace with class and message. Separately, the clustering rule from the
same run was fixed: all differences inside an HTML body are filed under one finding per
route (`response.body.html changed`), with the concrete paths kept as occurrences
(ADR 0019, docs/design/diff.md).

**Consequences.** + The `shop` run went from 24 findings and 156 noise paths to 1 real
finding with 0 noise. + The error pages compared are the ones users get. − Apps whose
error handling relies on `consider_all_requests_local` in tests now take the
production path in twins (RISKS R12).


---

## ADR 0022: Reproduction specs replay through a twin process, not an in-process request spec

**Status:** accepted (2026-11-03)

**Context.** PRODUCT asks for a "minimal RSpec request spec" for each finding. It must
pass on the current Rails and fail on the next, restoring the recorded snapshot through
a helper shipped with the gem. A conventional `type: :request` spec runs inside the
app's `test` environment, booted by `rails_helper`. That isn't where the finding was
observed. The twins run in the `doubletrack` environment overlay (memory cache store,
production error pages, inline jobs, intercepted HTTP, frozen clock, seeded `rand`). In
the `test` environment the same requests can behave differently: for example,
`consider_all_requests_local`, or the app's own test-only stubs. A repro that doesn't
reproduce is worse than none.

**Decision.** A generated spec calls `Doubletrack::Repro.replay(...)`. That starts one
twin of the app (the same `twin/main.rb`, overlay, clock, recorder and normalizer as
`doubletrack run`) using the Gemfile of the current `bundle exec`, so the dual-boot
convention selects the version. The spec asserts the old value at the finding's path in
the normalized trace. RSpec and Minitest output are both supported, chosen by
`repro_framework` (`auto` by default). The spec process never boots Rails itself, so it
works whether or not `rails_helper` was loaded. The app needs
`gem "doubletrack", require: false, group: :test`.

**Consequences.**
* \+ The repro uses the exact pipeline that found the difference, so "verified in the
  run" carries over to the spec.
* \+ It works with RSpec, Minitest, or plain `ruby`, regardless of the app's spec
  helpers.
* − It isn't an idiomatic `rails_helper` request spec. Translating it into one is left
  to the engineer, and the generated header says so.
* − It costs one twin boot per test process, a few seconds, shared by every repro in
  that process.
* − The app must add the gem to its bundle.

---

## ADR 0023: Reproductions are verified and minimized during the run, on the live twins

**Status:** accepted (2026-11-03)

**Context.** "Upgrade with proof, not hope." A rendered spec is only a claim until it
has been run. The finding's request may also depend on only some of the earlier
requests in its session. Replaying 30 requests to show a one-request change hides the
cause.

**Decision.** After analysis, while A, A′ and B are still booted, `doubletrack run`
replays each new finding's truncated session (up to the finding's request) on all three
twins. It counts as **reproduced** only if A and A′ both produce the expected value and
B doesn't. Then a greedy single pass tries to drop each earlier request (last to
first, at most 20 attempts), keeping a drop only if the result still reproduces. The
verdict and the observed values are stored in `repros.json` and shown in the report.
Repros that don't reproduce are still rendered, but labeled "not verified" with what was
observed.

**Consequences.**
* \+ The report only says "passes on old, fails on new" when that was observed.
* \+ Most repros shrink to the requests that matter.
* − Run time grows by up to 21 three-way session replays per new finding. These are
  cheap on booted twins, but noticeable for hundreds of findings. The 20-step cap bounds
  it.
* − Greedy one-pass removal is not guaranteed minimal (no full delta debugging), and
  params and stubs aren't minimized.
* − Verification runs in the twins, not by invoking the generated file under
  RSpec or Minitest. That end-to-end check is done by the integration spec and the eval.

---

## ADR 0024: Baseline matches by finding id; verdict and exit code count new findings only

**Status:** accepted (2026-11-03)

**Context.** Teams accept some differences as intended (for example, a new Rails
default they want). Those must stop failing CI without hiding *other* changes on the
same route.

**Decision.**
* `doubletrack.baseline.yml` (committed to the app) lists accepted finding ids, each
  with a required reason, an author, and a timestamp. Matching uses the id only: the
  ADR 0019 fingerprint, made of channel, route, generalized path, op and value shape,
  with values at enumerated leaves.
* Both `run` and `report` read the baseline. Accepted findings stay in `findings.json`
  and the report, marked `accepted`.
* Counts, the verdict and the exit code use new findings only.
* Entries not observed in a run are reported as stale, and never deleted
  automatically.
* `accept` refuses ids that aren't in the latest (or given) results, and requires a
  non-blank reason and an author.
* A malformed baseline is an error (exit 2).
* Doubletrack writes nothing else into the app: generated specs stay in the results
  directory, ready to copy.

**Consequences.**
* \+ Acceptance is reviewable in PRs, and it's attributable.
* \+ A different change at the same location (`200 → 500` instead of the accepted
  `200 → 422`) is a new finding.
* − A non-enumerated value change of the same shape is covered by an existing
  acceptance. For example, a string that changes differently next time. That's
  intended: the fingerprint describes the kind of difference, not every value.
* − Fingerprint changes in future Doubletrack versions would invalidate baselines. The
  fingerprint rules are therefore versioned through this ADR, and any change needs a new
  ADR and a migration note.

---

## ADR 0025: Capture sessions by hooking `ActionDispatch::Integration::Session#process` in the app's own test run

**Status:** accepted (2026-11-03)

**Context.** M5 derives replay sessions from the app's request tests. The options were:
* parse test source files (fragile: helpers, loops and computed paths);
* a Rack middleware in the test environment (it sees encoded requests and loses `as:`
  and the test boundaries);
* hooking the integration session that request tests already drive.

**Decision.** `doubletrack capture` runs the app's test command on the current Gemfile,
with `RUBYOPT=-r<gem>/lib/doubletrack/capture/boot.rb`. The boot file sets up the app's
bundle and registers lazy load hooks. These prepend a recorder to
`ActionDispatch::Integration::Session#process`, the method behind every `get`/`post` in
Minitest integration tests and RSpec request specs. The recorder takes the
*unencoded* arguments (method, path, params, headers, env, xhr, as) and the resulting
status. Requests are grouped per test, using the Minitest test name or the RSpec
example description. Each process writes its own file, so parallel test workers are
safe. The app needs nothing installed for capture, because the boot file is loaded by
path.

**Consequences.**
* \+ It works with Minitest and RSpec and with the tests' own helpers, with no changes
  to the app.
* \+ The captured shape is exactly what the twin replays: the twin calls the same
  method with the same arguments.
* − It depends on a Rails internal method signature. The hook passes through any
  arguments it doesn't understand, and the capture integration spec runs on both Rails
  versions in CI.
* − Requests that bypass the integration session (system tests, direct controller
  tests in old apps) aren't captured.

---

## ADR 0026: A `fixtures` snapshot kind for captured sessions

**Status:** accepted (2026-11-03)

**Context.** Tests run against fixture data, and their requests reference fixture
records by id. Replaying them on the schema-only snapshot turns those requests into
404s. The replay would then be faithful to the snapshot, but not to the test.

**Decision.**
* Sessions declare `"snapshot": "fixtures"` (captured ones always do) or `"default"`.
* `doubletrack run` builds one template per kind in use:
  * `default`: schema, plus seeds;
  * `fixtures`: schema, plus every fixture file under `test/fixtures` or
    `spec/fixtures`, loaded with `ActiveRecord::FixtureSet.create_fixtures`.
* Fixture ids are deterministic (a hash of the label), so captured ids resolve.
* Each session restores its own kind, and each reproduction carries its own snapshot
  file.

**Consequences.**
* \+ Captured sessions start from the state their tests started from.
* \+ Hand-written sessions are unaffected.
* − Two templates cost one more snapshot build when both kinds are used.
* − Fixtures that depend on test-only helpers in ERB won't load. The twin reports the
  fixture error and the run fails with exit 2 instead of replaying the wrong data.

---

## ADR 0027: Captured sessions are redacted against secret-looking environment variables, and capture fidelity is measured

**Status:** accepted (2026-11-03)

**Context.** Captured sessions are committed to the app's repo (R8). Tests send test
data, which is already in the repo. The realistic leak is a test that sends a real
credential read from the environment. Separately, a captured session is only evidence
if replaying it does what the test did, and nothing measured that.

**Decision.**
* **Redaction:** before writing, every string in a captured request that contains the
  value of an environment variable whose name matches
  `KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH` (8+ characters) has that value replaced
  with `[REDACTED:NAME]`. The count is reported. Raw records exist only in a deleted
  temp directory.
* **Fidelity:** each captured request keeps the status its test saw (`test_status`,
  informational). `doubletrack run` reports how many replayed requests got the same
  status on control A, with the mismatches listed. It's in `run.json`, the CLI and the
  report.

**Consequences.**
* \+ Leaking a CI secret through a captured header takes deliberate effort.
* \+ Users see which captured tests don't replay faithfully (for example app-level
  stubs, or `sign_in` helpers) instead of trusting coverage blindly.
* − Redaction is value-based. A secret not present in the environment of the capture
  process isn't caught.
* − Status equality is a coarse fidelity signal: same status, different body still
  counts as matched.

---

## ADR 0028: Survive Bundler re-executing the process (probe in RUBYOPT, twin fds sealed after the bundle)

**Status:** accepted (2026-11-05). Supersedes the "`-r`, not `RUBYOPT`" part of ADR 0025.

**Context.** When an app's lockfile was written by a newer Bundler (`BUNDLED WITH`
4.0.13 on once-campfire, while Ruby 3.4.12 ships 2.6.9), `require "bundler/setup"`
installs that version and re-executes the process with the same script and arguments.
The re-exec drops Ruby's command-line `-r` flags but keeps the environment
(`Bundler.with_original_env`). Two things broke on Campfire:
* `capture` loaded its probe with `ruby -r<probe> bin/rails test`. After the re-exec the
  probe was gone: 649 tests ran and 0 requests were captured.
* Twins opened their protocol pipes close-on-exec before loading the bundle, so the
  re-exec would have closed them and the twin would lose its coordinator.

**Decision.**
* `capture` puts the probe in `RUBYOPT=-r<probe>`. `capture/boot.rb` does nothing in a
  process whose bundle can't be set up or has no Active Support, because `RUBYOPT` also
  reaches every Ruby subprocess the tests start. A probe path with whitespace, which
  `RUBYOPT` can't quote, falls back to the command-line `-r`.
* Twins open the protocol fds inheritable, load the app's bundle, then mark them
  close-on-exec (`Twin::Fds.seal`). A re-exec during `bundler/setup` keeps the pipes;
  subprocesses the app starts afterwards still don't inherit them.

**Consequences.**
* \+ Apps whose lockfile names another Bundler version work without changes.
* \+ Subprocesses outside a bundle (a `ruby -e` a test shells out to) are untouched.
* − The probe now loads into every Ruby subprocess of the test run, including a
  `bundle` CLI a test might start, where it sets up the bundle first. It never raises,
  but it costs that process a `bundler/setup`.
* − The re-exec itself still installs the locked Bundler (network) when it isn't present.
  That is Bundler's behaviour, the same as running the app's own tests.

---

## ADR 0029: Restore snapshots in place with SQLite's backup API

**Status:** accepted (2026-11-05). Refines ADR 0004.

**Context.** A twin restored a snapshot by disconnecting Active Record, deleting the
database file and its `-wal`/`-shm` sidecars, and copying the template in. Apps may hold
SQLite connections outside Active Record's pool: once-campfire runs a WAL-checkpoint
thread (`SqliteWalCheckpoint`) that opens the file every 250 ms in non-test
environments, and Doubletrack's `doubletrack` environment is one. Replacing a file under
an open connection is a documented way to corrupt an SQLite database. On Campfire the
first queries of some sessions saw an empty schema (`no such table: bans`) on a random
twin, which became 25 false findings out of 48.

**Decision.** `Twin::SqliteRestore` copies the template into the live working database
through `SQLite3::Backup` (step -1, retrying while busy or locked, 30 s deadline). The
database file is never deleted between sessions. SQLite's locks keep every connection,
Active Record's or the app's, consistent. Building the template is unchanged.

**Consequences.**
* \+ The Campfire run went from 48 findings to 23; the 25 removed were all this race.
* \+ A connection the app keeps open sees the restored content (unit-specified).
* − The backup is a page copy through SQLite, slower than a file copy for large
  snapshots. Not measurable on Campfire's fixtures snapshot.
* − Background threads in the app still run during replay. Their effects are
  nondeterministic, and A/A′ comparison only catches nondeterminism that shows up in
  that run; reproduction verification is the second filter (see the M6 walkthrough).

---

## ADR 0030: Side effects from the app's own threads are recorded apart and not diffed

**Status:** accepted (2026-11-05)

**Context.** The recorder subscribed to Active Support notifications process-wide, so
an SQL write from any thread during a request was attributed to that request. Campfire
runs a web-push thread pool that deletes rejected subscriptions on its own schedule. On
Ruby 4.0.9 those deletes, left over from earlier sessions, landed in later requests'
traces on one twin or another: 15 findings, none of which reproduced.

**Decision.** The recorder remembers the thread that runs the request (and, for
performed jobs, the twin thread that performs them). SQL writes, enqueued jobs, mail and
cache operations notified from any other thread go to the trace's `background` list,
`{"thread", "channel", "entry"}`. `Normalize::Trace` drops `background`, so it is never
diffed. Jobs enqueued from other threads are not performed inline. Outbound HTTP is
unchanged.

**Consequences.**
* \+ An app's background pools no longer produce findings that depend on timing.
* \+ What they did stays visible in the raw trace.
* − A request that does its work in a thread it starts and joins (`Thread.new { ... }.join`)
  has that work recorded as background, so a Rails change to it is not reported.
  Specified on shop's `PATCH /orders/:id/audit`.

## ADR 0031: Findings that are one change across routes are grouped into a change

**Status:** accepted (2026-11-05)

**Context.** A finding is a difference at one route (ADR 0019), so one framework change
that affects every route is many findings: once-campfire PR #423 gave 22 findings that
were all `Vary` gaining `X-Requested-With`. Readers count distinct changes, not routes.

**Decision.** Findings with the same channel, generalized path, op and *delta* form a
change (`docs/design/changes.md`). The delta is a token-level description of how the
value changed (`{"added": ["X-Requested-With"], "removed": []}`), or the value shapes when
that isn't meaningful. Changes get stable ids (`c-…`). Findings, their ids, the baseline
and reproductions are unchanged; `accept c-…` accepts every finding of a change.

**Consequences.**
* \+ The report and CLI lead with what changed, then where.
* \+ No information is lost: findings stay per route, with their own repros.
* − Grouping is by exact delta, so text that differs per route (interpolated ids) is
  not grouped.

## ADR 0032: Likely causes are found locally, from the bundle's own sources

**Status:** accepted (2026-11-05)

**Context.** The next question after "what changed" is "which upgrade did it". The brief
rules out network calls, but the answer is usually on disk: Bundler keeps a full clone
of git-sourced gems (`Bundler::Source::Git#cache_path`), and every installed gem ships
its source and usually a changelog. A pickaxe search for `X-Requested-With` between
Campfire's two Rails revisions finds exactly `e38dd281d3` in about 5 seconds.

**Decision.** Twins report their loaded gems in `hello`; the coordinator records the gems
whose version or revision differs as `dependency_changes`. For each change, up to three
needles taken from its delta are searched in each changed dependency: commits between the
two revisions that add or remove the needle (`git log -G`), new changelog lines, and source
files where the needle appears on one side only. Up to three causes are kept, labelled
"likely cause" with their evidence. The search has a time budget.

**Consequences.**
* \+ Offline, no API, no tokens; works for Rails from git and for released gems.
* \+ The evidence is shown, so a reader can judge a match.
* − Text matching: changes with no distinctive text get no cause, and a common token can
  match an unrelated commit.
* − Commit evidence only for git-sourced gems; released gems get changelog and source
  evidence.

## ADR 0033: `init` writes `Gemfile.next` as a copy and never edits `Gemfile`

**Status:** accepted (2026-11-05)

**Context.** The next_rails convention makes `Gemfile.next` a symlink to `Gemfile` and
branches on `next?` inside it, which means editing the app's `Gemfile`. The brief forbids
mutating the target app's code. Campfire's M6 setup used a copy of `Gemfile` instead and
worked unchanged.

**Decision.** If the `Gemfile` already defines `next?`, `init` symlinks `Gemfile.next` to it
and tells the user which branch to edit. Otherwise it writes `Gemfile.next` as a copy of
`Gemfile` with only the `gem "rails"` statement replaced, and `Gemfile.next.lock` as a copy
of `Gemfile.lock`, so Bundler moves only Rails and what it needs. It writes new files only,
never overwrites one without `--force`, and runs `bundle install` only with `--install`.

**Consequences.**
* \+ One command; the app's own files are untouched.
* \+ The lockfile copy makes the next bundle look like a real upgrade PR.
* − Two Gemfiles to keep in step during an upgrade; `doctor` checks both bundles.

## ADR 0034: `doctor` checks what M6 tripped over, and exits 1 on a failed check

**Status:** accepted (2026-11-05)

**Context.** The problems found setting up Campfire were each a short message away from a
fix: missing system libraries, Bundler re-execution, the wrong Ruby, unsupported adapters.

**Decision.** `doctor` runs a fixed list of checks (`docs/design/setup.md`), each `ok`,
`warn` or `fail` with a fix, and by default boots control A and candidate B the way `run`
does. It exits 0 with only warnings, 1 with a failure (like `run`'s "differences found"),
and 2 when it can't run.

**Consequences.**
* \+ A setup problem is named before a long run fails.
* − The boot check takes as long as booting the app twice; `--no-boot` skips it.

## ADR 0035: Releases use RubyGems trusted publishing from a tag; the maintainer publishes

**Status:** accepted (2026-11-05)

**Context.** Publishing to rubygems.org is outward-facing and irreversible (a version can be
yanked but not reused), and needs the maintainer's account.

**Decision.** A `release.yml` workflow publishes on a `v*` tag through RubyGems trusted
publishing (OIDC), so no API key is stored anywhere. The maintainer configures the trusted
publisher once and pushes each tag. CI proves every commit packages correctly by installing
the built gem into an empty directory and running it on shop.

**Consequences.**
* \+ No long-lived secret; a release is one tag push by the maintainer.
* \+ A file missing from `spec.files` fails CI, not a user's install.
* − The first release waits for the maintainer to set up rubygems.org.

## ADR 0036: The GitHub Action is a composite action that runs the gem from its own source

**Status:** accepted (2026-11-05)

**Context.** The workflow that sells Doubletrack is "every Rails-bump PR gets a behavior
diff". The action must run the same Doubletrack as its tag, work before the gem is on
rubygems.org, and keep everything inside the user's GitHub.

**Decision.** `action.yml` at the repository root is a composite action. It builds and
installs the gem from `github.action_path`, installs both bundles, optionally captures
sessions, runs Doubletrack, writes `summary.md` to the job summary, and uploads the results
(without raw traces) as an artifact. With `comment: true` it keeps a single PR comment,
found by a marker, up to date. `fail-on` maps the run's counts to the step's status.
Doubletrack failing (exit 2) always fails the step.

**Consequences.**
* \+ Pinning the action pins Doubletrack; no rubygems.org dependency.
* \+ No new service: job summary, artifacts and a comment in the user's own repository.
* − The app's Ruby and system libraries are the workflow's job (documented).
* − Building the gem adds a few seconds per run.
