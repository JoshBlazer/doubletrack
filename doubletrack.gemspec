# frozen_string_literal: true

require_relative "lib/doubletrack/version"

Gem::Specification.new do |spec|
  spec.name = "doubletrack"
  spec.version = Doubletrack::VERSION
  spec.authors = ["JoshBlazer"]
  spec.summary = "Upgrade Rails with proof, not hope."
  spec.description = <<~DESC
    Doubletrack replays real or synthesized traffic against a Rails app running on the
    current and the next Rails version side by side, and reports every behavioral
    difference (responses, database writes, jobs, mail, cache, outbound HTTP), each
    backed by a minimal reproduction spec.
  DESC
  spec.homepage = "https://github.com/JoshBlazer/doubletrack"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "exe/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["doubletrack"]
  spec.require_paths = ["lib"]

  # No runtime dependencies: the standard library only (see docs/DECISIONS.md).
end
