# Design note: changes and their likely causes (M7)

Status: **accepted for M7**. Related: ADR 0031 (findings grouped into changes), ADR 0032
(local attribution), ADR 0019 (finding identity), `docs/formats/findings.md`.

## Goal

On once-campfire PR #423 the report listed 22 findings that were one Rails change, and
finding which Rails commit caused it took a manual search. A reader's first two
questions are "how many distinct things changed?" and "why?". M7 answers both, offline.

**Exit check** (ROADMAP): on the shop and planted fixtures and on the Campfire run,
* findings that are the same change on different routes are grouped into one *change*:
  Campfire's 22 `Vary` findings become **1 change, 22 routes**, and on the planted app
  no change mixes findings of two different plants (`make eval` checks it);
* each change lists likely causes found on this machine: Campfire's names Rails commit
  `e38dd281d3`, and shop's names the `json` gem;
* `doubletrack accept c-…` accepts every finding of a change.

## Changes (ADR 0031)

A finding is a difference at one route (ADR 0019). A **change** is a set of findings
with the same channel, generalized path, op and *delta*, whatever the route.

```ruby
module Doubletrack::Diff
  module Delta
    # @return [Hash] canonical, JSON-able description of how a became b
    #   strings:  {"added" => [tokens], "removed" => [tokens]}  (multiset difference of
    #             tokens split on whitespace , ; = ( ) and quotes, sorted, deduped)
    #   otherwise, or strings whose token sets are equal: {"from" => shape(a), "to" => shape(b)}
    #             where shape follows Fingerprint.shape (values at enumerated leaves,
    #             types elsewhere)
    def self.call(path, a, b) = ...
  end

  module Changes
    # Groups findings into changes; sets "change_id" on each finding.
    # @param findings [Array<Hash>] as clustered (with occurrences)
    # @return [Array<Hash>] changes, sorted like findings (severity, then size)
    def self.call(findings) = ...
  end
end
```

* A finding's delta is the sorted set of its occurrences' deltas. Campfire's three
  `Vary` shapes (`Accept` → `Accept, X-Requested-With`, …) all give
  `{"added" => ["X-Requested-With"], "removed" => []}`.
* Change id: `c-` + 12 hex of SHA-256 over `[kind, path, op, delta]`, stable across runs
  like a finding id.
* A change's severity is its most severe finding's. It is *accepted* when all its
  findings are accepted; otherwise its accepted findings are listed but not counted.
* Summary text, from the delta: `adds X-Requested-With`, `removes …`, `200 → 500`,
  `string → null`, or `changed` for HTML bodies.

## Likely causes (ADR 0032)

Everything is local. A cause is *evidence that a dependency change mentions the
change's text*, never a proof. The report says "likely cause" and shows the evidence.

**What changed in the bundle.** Twins add `gems` to `hello`:
`[{"name", "version", "revision", "path", "git_cache", "remote"}]` from
`Gem.loaded_specs` (`revision`, `git_cache` and `remote` only for git sources, through
`Bundler::Source::Git#revision`, `#cache_path`, `#uri`). The coordinator keeps gems whose
version or revision differs between control A and candidate B as
`run.json` `dependency_changes`:
`[{"name", "from", "to", "from_path", "to_path", "git" => {"cache", "from", "to", "remote"} | nil}]`.
Gems from one git repository (rails, actionpack, …) are one entry, named after the
repository.

**Needles** (`Attribution::Needles.call(change) → [String]`, at most 3): the delta's
added tokens, then removed ones, that are at least 4 characters and contain a letter
and aren't a stop word; for strings, runs of 2+ consecutive added words first ("end of
input"). Enumerated values (`200 → 500`) give no needles, so no causes.

**Evidence, per changed dependency and needle, best first:**
1. **commit**: `git -C <git_cache> log --format=%H%x1f%s -i -G<escaped needle>
   --max-count=3 <from>..<to>` when the cache has both revisions. A GitHub remote gives
   a commit URL.
2. **changelog**: lines in any `CHANGELOG.md` under `to_path` that aren't in the same
   file under `from_path`, mentioning the needle; the entry's first line is shown.
3. **source**: files under `to_path/{lib,ext}` that contain the needle when no file
   under `from_path` does (or the reverse for removed tokens).

A change keeps at most 3 causes, deduplicated by reference. The whole search has a time
budget (default 60 s); when it runs out, the remaining changes say "not searched". No
`git` on the PATH skips commit evidence.

```ruby
module Doubletrack::Attribution
  # @param changes [Array<Hash>] from Diff::Changes, modified in place ("causes")
  # @param dependency_changes [Array<Hash>] from run.json
  # @return [Array<Hash>] changes
  def self.call(changes, dependency_changes:, budget_s: 60, git: "git") = ...
end
```

## Formats, report, CLI

* `findings.json` becomes `findings_version` 2: a top-level `changes` array, and
  `change_id` on each finding. `run.json` gains `dependency_changes` and
  `counts.changes` (new changes only).
* Report: the overview lists changes (summary, severity, routes, verified count, likely
  cause) and the bundle changes. The findings page groups findings under their change.
  A finding page links to its change and shows its likely causes.
* CLI summary: `Findings: 22 new in 1 change (...)`, then one line per change.
* `doubletrack accept c-…` writes one baseline entry per finding of the change. The
  baseline still matches by finding id (ADR 0024).

## Limitations

* Grouping is by exact delta. The same Rails change showing up as different text on
  different routes (a message with an interpolated id) stays separate changes.
* Causes are text matches. A change whose text appears in no commit diff, changelog or
  source file (a behavior change with no new string) gets no cause. A common token can
  point at an unrelated commit; the evidence is shown so a reader can judge.
* Commit evidence needs Bundler's git cache, which only git-sourced gems have. Released
  gems get changelog and source evidence.
