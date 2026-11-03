# frozen_string_literal: true

require_relative "lib/doubletrack/version"

Gem::Specification.new do |spec|
  spec.name = "doubletrack"
  spec.version = Doubletrack::VERSION
  spec.authors = ["JoshBlazer"]
  spec.summary = "Upgrade Rails with proof, not hope."
  spec.description = <<~DESC
    Doubletrack replays traffic (captured from the app's tests, or hand-written) against
    a Rails app running on the current and the next Rails version side by side. It
    reports the behavioral differences it observes (responses, database writes, jobs,
    mail, cache, outbound HTTP) and writes a reproduction spec for each new finding,
    checked during the run.
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

  spec.files = Dir["lib/**/*.{rb,erb,css,js}", "exe/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["doubletrack"]
  spec.require_paths = ["lib"]

  # The only runtime dependency (ADR 0017): HTML normalization in the coordinator.
  # Twin code never loads it; twins use the standard library only.
  spec.add_dependency "nokogiri", ">= 1.13", "< 2"
end
