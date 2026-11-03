# frozen_string_literal: true

require "bundler"
require "json"
require "open3"
require "yaml"
require_relative "../lib/doubletrack"
require_relative "../lib/doubletrack/coordinator/run"
require_relative "../lib/doubletrack/specgen"

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

  # Runs every generated reproduction for real (M4): all Minitest files in one process per
  # Gemfile, under the app's own bundle, with the gem's lib on the load path. A repro is
  # confirmed when it was verified in the run, passes on the current Rails and fails on
  # the next.
  class ReproCheck
    LINE = /^(DoubletrackRepro\w+Test)#\S+ = [\d.]+ s = ([.FES])$/
    CODES = {"." => :pass, "F" => :fail, "E" => :error, "S" => :skip}.freeze
    RUNNER = 'files = ARGV.dup; ARGV.replace(["-v"]); files.each { |f| require File.expand_path(f) }'

    def self.parse_minitest(output, ids)
      by_class = ids.to_h { |id| [Doubletrack::Specgen::Writer.class_name(id), id] }
      results = ids.to_h { |id| [id, :missing] }
      output.each_line do |line|
        m = LINE.match(line.chomp) or next
        id = by_class[m[1]] or next
        results[id] = CODES.fetch(m[2])
      end
      results
    end

    def self.score(repros, on_current, on_next)
      confirmed = repros.select do |r|
        r["status"] == "reproduced" && on_current[r["finding_id"]] == :pass && on_next[r["finding_id"]] == :fail
      end
      {
        "generated" => repros.size,
        "verified_in_run" => repros.count { |r| r["status"] == "reproduced" },
        "pass_on_current" => repros.count { |r| on_current[r["finding_id"]] == :pass },
        "fail_on_next" => repros.count { |r| on_next[r["finding_id"]] == :fail },
        "confirmed" => confirmed.size,
        "unconfirmed" => repros.map { |r| r["finding_id"] } - confirmed.map { |r| r["finding_id"] }
      }
    end

    def initialize(app_root:, results_dir:)
      @app_root = app_root
      @results_dir = results_dir
    end

    # @return [Hash] score
    def call
      data = JSON.parse(File.read(File.join(@results_dir, "repros.json")))
      raise Doubletrack::Error, "eval runs Minitest repros only (got #{data["framework"]})" unless data["framework"] == "minitest"

      repros = data["repros"]
      files = repros.filter_map { |r| r["file"] && File.join(@results_dir, r["file"]) }
      ids = repros.map { |r| r["finding_id"] }
      return self.class.score(repros, {}, {}) if files.empty?

      on_current = self.class.parse_minitest(run_all("Gemfile", files), ids)
      on_next = self.class.parse_minitest(run_all("Gemfile.next", files), ids)
      self.class.score(repros, on_current, on_next)
    end

    private

    def run_all(gemfile, files)
      lib = File.join(ROOT, "lib")
      output, = Bundler.with_unbundled_env do
        Open3.capture2e({"BUNDLE_GEMFILE" => File.join(@app_root, gemfile)}, "bundle", "exec", "ruby", "-I", lib, "-Itest",
          "-e", RUNNER, *files, chdir: @app_root)
      end
      output
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
        @progress.puts("== eval: running #{name}'s reproductions on both Gemfiles")
        score["repros"] = ReproCheck.new(app_root: root, results_dir: result.dir).call
        [name, score]
      end
      changes = apps["changes"]
      repros = changes["repros"]
      pass = changes["missed"].empty? && changes["unexpected"].empty? && apps["clean"]["findings"].zero? &&
        repros["generated"] == changes["findings"] && repros["confirmed"] == repros["generated"]
      {"eval_version" => 1, "seed" => @seed, "doubletrack_version" => Doubletrack::VERSION, "apps" => apps, "pass" => pass}
    end

    private

    def expected(root)
      YAML.safe_load_file(File.join(root, "doubletrack", "expected.yml")).fetch("plants")
    end
  end
end
