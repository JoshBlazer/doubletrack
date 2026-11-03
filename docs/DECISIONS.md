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
