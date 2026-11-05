# Design note: `init`, `doctor` and the 0.1.0 release (M8)

Status: **accepted for M8**. Related: ADR 0033 (`init` writes `Gemfile.next`, never edits
`Gemfile`), ADR 0034 (`doctor` checks and exit codes), ADR 0035 (releases), ADR 0001
(next_rails convention), ADR 0008 (supported Rails pairs).

## Goal

Setting up Campfire for M6 took hand-made `Gemfile.next` and `Gemfile.next.lock` files, two
`bundle install`s and a missing system library found from a boot error. A new user should
need one command to set up, one to check, and then `capture` and `run`. And they should be
able to `gem install doubletrack`.

**Exit check** (ROADMAP):
* `doubletrack init --to 8.1` on a copy of a Rails 8.0 fixture with its `Gemfile.next*`
  removed writes a working `Gemfile.next`; with `--install`, both bundles install and
  `doctor` passes;
* `doctor` names each problem in a broken setup (missing `Gemfile.next.lock`, a non-SQLite
  adapter, an unintercepted HTTP client) with a fix, and exits 1;
* the gem builds, installs into an empty `GEM_HOME`, and `doubletrack run` from the
  installed executable replays shop (CI job `installed-gem`).

## `doubletrack init [APP_DIR] [--to VERSION] [--install]`

```
1. read Gemfile.lock (Bundler::LockfileParser): the current Rails version or git revision
2. target: --to "8.1" | "8.1.2" | "main"; default: the next minor, "~> X.(Y+1).0"
3. Gemfile.next:
   - the Gemfile defines `next?` (next_rails convention): symlink Gemfile.next → Gemfile,
     and say which `if next?` branch to edit; nothing else is written
   - otherwise: a copy of Gemfile with the `gem "rails", …` statement replaced by
     `gem "rails", "~> 8.1.0"` (or `github: "rails/rails", branch: "main"`), and a header
     comment saying it was written by `doubletrack init`
   - an existing Gemfile.next is never overwritten (error, unless --force)
4. Gemfile.next.lock: a copy of Gemfile.lock, so Bundler resolves conservatively (only Rails
   and what it needs move, like a real upgrade PR)
5. doubletrack/sessions/ (with a README pointing at `doubletrack capture`)
6. --install: `bundle install` with BUNDLE_GEMFILE=Gemfile.next (the user's Bundler, the
   user's gem sources). Without it, init prints that command.
7. prints the next steps: install, doctor, capture, run
```

`init` never edits `Gemfile`, `Gemfile.lock` or application code (hard constraint: never
mutate the target app's code). It writes only new files.

```ruby
module Doubletrack
  module Setup
    # @return [Hash] {"from" => "8.0.5.1", "to_requirement" => "~> 8.1.0", "written" => [paths], "mode" => "copy"|"symlink"}
    def self.init(app_root, to: nil, force: false, install: false, out: $stdout) = ...
    # gem "rails", ... statements (one or more lines ending in a comma) replaced
    def self.rewrite_rails(gemfile_text, requirement) = ...
    def self.next_requirement(version_string, to) = ...
  end
end
```

## `doubletrack doctor [APP_DIR] [--no-boot]`

Each check is `{"name", "status" => "ok"|"warn"|"fail", "detail", "fix"}`, printed one per
line. Exit 0 when nothing fails (warnings allowed), 1 when a check fails, 2 when doctor
itself can't run.

| Check | Fails when | Warns when |
|---|---|---|
| platform | native Windows | – |
| ruby | Ruby < 3.2 | the app's `.ruby-version` differs from the running Ruby (one Ruby for both twins until M11) |
| dual boot | `Gemfile`, `Gemfile.lock`, `Gemfile.next` or `Gemfile.next.lock` is missing | – |
| rails versions | both lockfiles resolve the same Rails version and revision | the pair isn't adjacent minors (ADR 0008) |
| bundles | `bundle check` fails for either Gemfile (with its output) | – |
| database | `config/database.yml`'s test database isn't SQLite (until M10), or there's no `db/schema.rb` | – |
| http clients | – | the bundle has `httpx`, `typhoeus`, `curb`, `excon`, `patron` or `http` (not intercepted, R6) |
| sessions | – | no `doubletrack/sessions/*.jsonl` (run `doubletrack capture`) |
| git | – | no `git` on the PATH (likely causes won't name commits) |
| boot | a twin fails to boot (with the end of its log), or both load the same Rails | – |

`boot` starts control A and candidate B with the same code `run` uses and reports both Rails
versions and boot times. `--no-boot` skips it.

## Release (ADR 0035)

* `VERSION = "0.1.0"`; `CHANGELOG.md` gets a `[0.1.0]` section.
* `.github/workflows/release.yml`: on a `v*` tag, run the gates, build the gem, publish with
  RubyGems trusted publishing (`rubygems/release-gem`, OIDC, no stored API key), and attach
  the `.gem` to a GitHub release.
* Publishing needs the maintainer: configure the trusted publisher on rubygems.org and push
  the tag. `docs/RELEASING.md` lists the steps.
* CI job `installed-gem`: `gem build`, `gem install --install-dir` into an empty directory,
  then run that `doubletrack` on shop with `GEM_HOME` pointing there, so a file missing from
  `spec.files` fails CI.
