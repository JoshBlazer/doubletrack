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

**Status:** accepted (2026-11-03). Implementation lands in M2.

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

**Status:** accepted (2026-11-03). Implementation lands in M3.

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

