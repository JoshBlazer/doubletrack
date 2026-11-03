# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../lib/doubletrack"
require_relative "../lib/doubletrack/coordinator/run"

# Precision/recall harness over the planted fixtures (ADR 0020, docs/design/diff.md).
# Used by `make eval` (eval/run.rb) and spec/integration/eval_spec.rb.
module DoubletrackEval
  ROOT = File.expand_path("..", __dir__)
  APPS = {
    "changes" => File.join(ROOT, "fixtures/apps/planted/changes"),
    "clean" => File.join(ROOT, "fixtures/apps/planted/clean")
  }.freeze

  # Matches findings against planted expectations.
  class Matcher
    # @param plants [Array<Hash>] expected.yml "plants"
    def initialize(plants)
      @plants = plants
    end

    # @param findings [Array<Hash>]
    # @return [Hash] caught, missed, unexpected, precision, recall
    def call(findings)
      matched = {}
      caught = @plants.select do |plant|
        hits = findings.select { |f| matches?(plant, f) }
        hits.each { |f| matched[f["id"]] = true }
        hits.any?
      end
      unexpected = findings.reject { |f| matched[f["id"]] }
      {
        "plants" => @plants.size,
        "findings" => findings.size,
        "caught" => caught.map { |p| p["id"] },
        "missed" => (@plants - caught).map { |p| p["id"] },
        "unexpected" => unexpected.map { |f| f.slice("id", "severity", "route", "path", "op") },
        "recall" => @plants.empty? ? 1.0 : caught.size.fdiv(@plants.size),
        "precision" => findings.empty? ? 1.0 : (findings.size - unexpected.size).fdiv(findings.size)
      }
    end

    private

    def matches?(plant, finding)
      return false unless finding["severity"] == plant["severity"]

      plant["findings"].any? do |e|
        finding["route"] == e["route"] && path_under?(finding["path"], e["path"])
      end
    end

    # "a.b" is under "a" and "a.b"; "a[*].c" is under "a"; "ab" is not under "a".
    def path_under?(path, prefix)
      path == prefix || path.start_with?("#{prefix}.") || path.start_with?("#{prefix}[")
    end
  end

  # Runs Doubletrack on both planted apps and scores the results.
  class Harness
    def initialize(out_dir:, seed: 7, progress: $stderr)
      @out_dir = out_dir
      @seed = seed
      @progress = progress
    end

    # @return [Hash] {"apps" => {name => score}, "pass" => Boolean}
    def call
      apps = APPS.to_h do |name, root|
        @progress.puts("== eval: #{name} (#{root})")
        config = Doubletrack::Config.load(root)
        result = Doubletrack::Coordinator::Run.new(config: config, out_dir: File.join(@out_dir, name), seed: @seed,
          progress: @progress).call
        plants = (name == "clean") ? [] : expected(root)
        score = Matcher.new(plants).call(result.findings).merge(
          "run_id" => result.run["run_id"],
          "results_dir" => result.dir,
          "noise_suppressed" => result.run.dig("noise", "suppressed"),
          "coverage" => result.run.dig("coverage", "ratio"),
          "rails" => [result.run.dig("twins", "control_a", "rails_version"), result.run.dig("twins", "candidate_b", "rails_version")]
        )
        [name, score]
      end
      changes = apps["changes"]
      pass = changes["missed"].empty? && changes["unexpected"].empty? && apps["clean"]["findings"].zero?
      {"eval_version" => 1, "seed" => @seed, "doubletrack_version" => Doubletrack::VERSION, "apps" => apps, "pass" => pass}
    end

    private

    def expected(root)
      YAML.safe_load_file(File.join(root, "doubletrack", "expected.yml")).fetch("plants")
    end
  end
end
