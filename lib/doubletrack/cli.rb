# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../doubletrack"
require_relative "config"

module Doubletrack
  # Command-line entry point. Commands that aren't built yet say which milestone delivers
  # them and exit 2, so nothing pretends to work.
  class CLI
    COMMANDS = {
      "init" => ["detect Rails version, set up/verify dual boot, write doubletrack.yml", "M5"],
      "doctor" => ["verify both versions boot and report environment problems", "M5"],
      "capture" => ["derive sessions from the app's request/integration tests", "M5"],
      "run" => ["replay sessions on control A, control A', and candidate B", nil],
      "report" => ["(re)generate findings and the static HTML report from stored results", nil],
      "accept" => ["mark a finding as expected in doubletrack.baseline.yml", "M4"],
      "bisect" => ["find the Rails version, then commit, that introduced a finding", "L1"],
      "defaults" => ["test each new framework default individually", "L2"]
    }.freeze

    def self.start(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).call(argv)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    # @return [Integer] exit code
    def call(argv)
      command, *args = argv
      case command
      when nil, "help", "-h", "--help"
        @out.puts(usage)
        EXIT_OK
      when "version", "-v", "--version"
        @out.puts("doubletrack #{VERSION}")
        EXIT_OK
      when "run" then run(args)
      when "report" then report(args)
      when *COMMANDS.keys
        @err.puts("doubletrack #{command}: not implemented yet (planned for #{COMMANDS[command][1]}; see docs/ROADMAP.md)")
        EXIT_ERROR
      else
        @err.puts("doubletrack: unknown command #{command.inspect}\n\n#{usage}")
        EXIT_ERROR
      end
    rescue Doubletrack::Error, OptionParser::ParseError => e
      @err.puts("doubletrack #{command}: #{e.message}")
      if e.respond_to?(:log_tail) && e.log_tail && !e.log_tail.empty?
        @err.puts("--- last lines of twin log (#{e.role}) ---\n#{e.log_tail}")
      end
      EXIT_ERROR
    end

    private

    def run(args)
      options = {}
      overrides = {}
      parser = OptionParser.new do |o|
        o.banner = "Usage: doubletrack run [APP_DIR] [options]"
        o.on("--sessions DIR", "sessions directory (default doubletrack/sessions)") { |v| overrides["sessions"] = File.expand_path(v) }
        o.on("--out DIR", "results parent directory (default APP_DIR/tmp/doubletrack)") { |v| options[:out] = v }
        o.on("--seed N", Integer, "run seed (recorded; reproduces a run)") { |v| options[:seed] = v }
        o.on("--[no-]perform-jobs", "perform enqueued jobs inline (default on, ADR 0014)") { |v| overrides["perform_jobs"] = v }
        o.on("--[no-]seeds", "load db/seeds.rb into the snapshot") { |v| overrides["seeds"] = v }
      end
      rest = parser.parse(args)
      raise ConfigError, "expected at most one APP_DIR, got #{rest.join(" ")}" if rest.size > 1

      require_relative "coordinator/run"
      config = Config.load(File.expand_path(rest.first || "."), overrides)
      result = Coordinator::Run.new(config: config, out_dir: options[:out], seed: options[:seed], progress: @err).call
      summarize(result.dir, result.run, result.findings)
    end

    def report(args)
      dir = args.first or raise ConfigError, "usage: doubletrack report RESULTS_DIR"
      dir = File.expand_path(dir)
      path = File.join(dir, "run.json")
      raise ConfigError, "#{path} not found (expected a results/<run_id> directory)" unless File.exist?(path)

      require_relative "results"
      run, findings = Results.analyze(dir, JSON.parse(File.read(path)))
      summarize(dir, run, findings)
      EXIT_OK
    end

    def summarize(dir, run, findings)
      counts = run["counts"]
      coverage = run["coverage"]
      twins = run["twins"]
      @out.puts("Doubletrack #{run["run_id"]}: #{run.dig("app", "name")}, " \
        "Rails #{twins.dig("control_a", "rails_version")} → #{twins.dig("candidate_b", "rails_version")}")
      @out.puts("  #{run["sessions"].size} sessions, #{run["sessions"].sum { |s| s["requests"] }} requests " \
        "replayed on control A, control A′ and candidate B")
      @out.puts("  Findings: #{counts["findings"]}  (data-changing #{counts["data-changing"]}, " \
        "user-visible #{counts["user-visible"]}, cosmetic #{counts["cosmetic"]})")
      findings.first(10).each do |f|
        @out.puts("    [#{f["severity"]}] #{f["title"]}  (#{f["sessions"]} session#{"s" unless f["sessions"] == 1}, #{f["id"]})")
      end
      @out.puts("    ... #{findings.size - 10} more in the report") if findings.size > 10
      @out.puts("  Noise filtered: #{run.dig("noise", "suppressed")} " \
        "(#{run.dig("noise", "a_vs_a_prime_differences")} A/A′ differences observed)")
      @out.puts("  Route coverage: #{coverage["routes_hit"]} of #{coverage["routes_total"]} routes (#{(coverage["ratio"] * 100).round}%)")
      @out.puts("  Verdict: #{(run["verdict"] == "ready") ? "Ready to ship" : "Not ready to ship"}")
      @out.puts("  Report: #{File.join(dir, "report", "index.html")}")
      findings.empty? ? EXIT_OK : EXIT_DIFFERENCES
    end

    def usage
      lines = COMMANDS.map do |name, (summary, milestone)|
        format("  %-9s %s%s", name, summary, milestone ? " [#{milestone}]" : "")
      end
      <<~USAGE
        Usage: doubletrack COMMAND [options]

        Upgrade Rails with proof, not hope.

        Commands (not-yet-built ones show the milestone that delivers them):
        #{lines.join("\n")}
          version   print the version

        doubletrack run [APP_DIR] [--sessions DIR] [--out DIR] [--seed N] [--[no-]perform-jobs] [--[no-]seeds]
        doubletrack report RESULTS_DIR

        Exit codes: 0 no new differences, 1 new differences found, 2 Doubletrack error.
      USAGE
    end
  end
end
