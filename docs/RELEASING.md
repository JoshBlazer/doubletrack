# Releasing

Releases are published by the maintainer (ADR 0035). Nothing in this repository holds a
rubygems.org credential.

## One-time setup (rubygems.org)

1. Sign in to rubygems.org as the gem's owner (with MFA; the gemspec requires it).
2. Add a trusted publisher. For a gem that doesn't exist yet, use
   "Pending trusted publishers" on your profile:
   * gem name: `doubletrack`
   * repository: `JoshBlazer/doubletrack`
   * workflow: `release.yml`
   * environment: `rubygems`
3. In the GitHub repository settings, create the environment `rubygems` (optionally with
   required reviewers, so every publish waits for an approval).

## Each release

1. Update `Doubletrack::VERSION` in `lib/doubletrack/version.rb` and the fixture lockfiles
   (`doubletrack (x.y.z)` in `fixtures/apps/shop/Gemfile*.lock`).
2. Move the `[Unreleased]` entries in `CHANGELOG.md` under the new version, with the date.
3. Commit, push, and wait for CI to be green on `main` (including `installed gem runs shop`).
4. Tag and push the tag:

       git tag -a vX.Y.Z -m "vX.Y.Z"
       git push origin vX.Y.Z

5. The `Release` workflow checks that the tag matches the version, runs lint, unit specs
   and the packaging check, publishes with trusted publishing, and creates a GitHub
   release with the `.gem` attached.

A published version can be yanked (`gem yank doubletrack -v X.Y.Z`) but its number can't be
reused.
