# Design note: a Ruby per twin (M11)

Status: **accepted for M11**. Related: ADR 0038 (each Gemfile gets its own Ruby,
found locally), RISKS R1 (environment leaks), R19.

## Goal

Doubletrack ran both twins on its own Ruby. Campfire needs Ruby 4.0.9 (`.ruby-version`), so
M6 had to run all of Doubletrack under 4.0.9. Rails upgrades also often come with a Ruby
upgrade. Each side should run on the Ruby it's meant to run on.

**Exit check** (ROADMAP): in CI, candidate B runs on a different Ruby than control A (two
Rubies installed side by side), and the run reports both versions and finds shop's change.

## Configuration

`doubletrack.yml` (and `--ruby` / `--next-ruby` on `run` and `capture`):

| Key | Default | Values |
|---|---|---|
| `ruby` | `auto` | Ruby for control A and A′ (and `capture`) |
| `next_ruby` | the value of `ruby` | Ruby for candidate B |

Each value is one of:
* `auto`: the app's `.ruby-version` when there is one and it's installed; otherwise the Ruby
  running Doubletrack;
* `current`: the Ruby running Doubletrack;
* a version (`4.0.9`, `ruby-4.0.9`): an installed Ruby of that version;
* a path to a `ruby` executable.

## Finding an installed Ruby (`RubyLocator`)

Version strings are looked up on disk only, never installed. These places are checked, in
order:
1. `$RBENV_ROOT/versions/V` (default `~/.rbenv`);
2. `$ASDF_DATA_DIR/installs/ruby/V` (default `~/.asdf`);
3. `~/.local/share/mise/installs/ruby/V`;
4. `~/.rubies/ruby-V` and `/opt/rubies/ruby-V` (chruby);
5. `~/.rvm/rubies/ruby-V`;
6. the GitHub Actions tool cache (`$RUNNER_TOOL_CACHE/Ruby/V/x64`).

The candidate's `bin/ruby` must run and report `RUBY_VERSION == V`. An unknown version is a
`ConfigError` that lists the places searched.

```ruby
module Doubletrack
  module RubyLocator
    # @return [Hash] {"path", "version", "source"}  source: current | .ruby-version | config
    def self.resolve(spec, app_root:) = ...
    def self.find(version, env: ENV) = ... # path or nil
  end
end
```

## Spawning a twin on another Ruby

`TwinProcess` gets `ruby:` (a path). When it differs from the coordinator's Ruby, the
twin's environment changes in three ways:
* `GEM_HOME`, `GEM_PATH` and `GEM_ROOT` are removed, so that Ruby uses its own gems (R1);
* the Ruby's `bin` directory goes first on `PATH`, so `bundle` and any `ruby` the app
  starts are that Ruby's;
* `RBENV_VERSION`, `ASDF_RUBY_VERSION` and `MISE_RUBY_VERSION` are removed, because a shim
  must not pick another Ruby.

The twin code only needs Ruby 3.2+ and the app's bundle, so it runs under any supported
Ruby. `hello` already reports `ruby_version`; `run.json` and the report show it per twin.
The dual-boot check (`RailsLabel.check!`) is unchanged: A and A′ always share a Ruby.

`capture` runs the app's tests on the `ruby` setting. Reproduction specs run in the user's
own test process; the generated file's header names the Ruby each side used.

## doctor

The ruby check reports the Ruby for each side. It fails when a configured Ruby isn't found,
and it no longer warns about `.ruby-version` when that version is installed (`auto` will use
it).

## Limitations

* Rubies are found, not installed.
* Both bundles must be installed for their own Ruby (`doctor`'s bundle check runs
  `bundle check` with each).
* A change caused by the Ruby upgrade and one caused by the Rails upgrade land in one report.
  Likely causes help tell them apart: default gems show up in `dependency_changes`.
