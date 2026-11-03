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
      "capture" => ["derive sessions from the app's request/integration tests", nil],
      "run" => ["replay sessions on control A, control A', and candidate B", nil],
      "report" => ["(re)generate findings and the static HTML report from stored results", nil],
      "accept" => ["mark a finding as expected in doubletrack.baseline.yml", nil],
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
      when "accept" then accept(args)
      when "capture" then capture(args)
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
        o.on("--baseline FILE", "accepted findings (default APP_DIR/doubletrack.baseline.yml)") { |v| overrides["baseline"] = File.expand_path(v) }
        o.on("--repro-framework NAME", "auto, rspec or minitest (default auto)") { |v| overrides["repro_framework"] = v }
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

    def accept(args)
      options = {}
      parser = OptionParser.new do |o|
        o.banner = "Usage: doubletrack accept ID --reason TEXT [APP_DIR] [options]"
        o.on("--reason TEXT", "why this difference is expected (required)") { |v| options[:reason] = v }
        o.on("--author TEXT", "who accepts it (default: git config user.name <user.email>)") { |v| options[:author] = v }
        o.on("--results DIR", "results directory with the finding (default: newest under APP_DIR/tmp/doubletrack)") { |v| options[:results] = File.expand_path(v) }
        o.on("--baseline FILE", "baseline file (default APP_DIR/doubletrack.baseline.yml)") { |v| options[:baseline] = File.expand_path(v) }
      end
      id, app_dir, *extra = parser.parse(args)
      raise ConfigError, "usage: doubletrack accept ID --reason TEXT [APP_DIR]" if id.nil? || !extra.empty?
      require_relative "baseline"
      raise ConfigError, "#{id.inspect} is not a finding id (f- and 12 hex digits, as shown in the report)" unless Baseline::ID_PATTERN.match?(id)
      raise ConfigError, "--reason TEXT is required: say why this difference is expected" if options[:reason].to_s.strip.empty?

      app_root = File.expand_path(app_dir || ".")
      results = options[:results] || newest_results(app_root)
      findings_path = File.join(results, "findings.json")
      raise ConfigError, "#{findings_path} not found: run `doubletrack run` first, or pass --results DIR" unless File.exist?(findings_path)

      finding = JSON.parse(File.read(findings_path))["findings"].find { |f| f["id"] == id }
      raise ConfigError, "#{id} not found in #{findings_path} (finding ids are listed in the report)" unless finding

      run = JSON.parse(File.read(File.join(results, "run.json")))
      author = options[:author] || git_author(app_root)
      raise ConfigError, "no author: pass --author TEXT, or set git config user.name in #{app_root}" if author.to_s.strip.empty?

      path = options[:baseline] || Config.load(app_root).baseline_path
      baseline = Baseline.load(path)
      outcome = baseline.accept(finding, reason: options[:reason], author: author, run: run)
      baseline.write
      @out.puts("#{(outcome == :added) ? "Accepted" : "Updated"} #{id} in #{path}")
      @out.puts("  #{finding["title"]} [#{finding["severity"]}]")
      @out.puts("  Commit #{File.basename(path)}; later runs list this finding as accepted and exit 0 if nothing else is new.")
      EXIT_OK
    end

    def capture(args)
      options = {}
      parser = OptionParser.new do |o|
        o.banner = "Usage: doubletrack capture [APP_DIR] [options]"
        o.on("--out FILE", "sessions file (default APP_DIR/doubletrack/sessions/captured.jsonl)") { |v| options[:out] = File.expand_path(v) }
        o.on("--command CMD", "Ruby script and arguments to run the tests (default: bin/rails test, or rspec)") { |v| options[:command] = v }
        o.on("--gemfile FILE", "bundle to run the tests on (default: the current Rails Gemfile)") { |v| options[:gemfile] = File.expand_path(v) }
      end
      rest = parser.parse(args)
      raise ConfigError, "expected at most one APP_DIR, got #{rest.join(" ")}" if rest.size > 1

      require_relative "capture"
      config = Config.load(File.expand_path(rest.first || "."), {"gemfile" => options[:gemfile]})
      summary = Capture::Runner.new(config: config, out: options[:out], command: options[:command], progress: @err).call
      stats = summary.stats
      @out.puts("Captured #{stats["sessions"]} sessions (#{stats["requests"]} requests) from #{stats["tests"]} tests that made requests")
      @out.puts("  tests: #{summary.tests_passed ? "passed" : "FAILED (exit #{summary.exit_status.inspect}); their requests were still captured"}")
      @out.puts("  duplicates written once: #{stats["duplicates"]}") if stats["duplicates"].positive?
      stats["skipped"].each { |s| @out.puts("  skipped #{s["test"]}: #{s["reason"]}") }
      @out.puts("  redacted #{stats["redactions"]} secret value#{"s" unless stats["redactions"] == 1} (ADR 0027)") if stats["redactions"].positive?
      @out.puts("  Written: #{summary.path}")
      sessions_dir = File.dirname(summary.path)
      next_run = "doubletrack run #{rest.first || "."}"
      next_run += " --sessions #{sessions_dir}" unless sessions_dir == config.sessions_dir
      @out.puts("  Next: #{next_run}  (captured sessions replay on the fixtures snapshot, ADR 0026)")
      unless summary.tests_passed
        @err.puts("--- last lines of the test output ---\n#{summary.output_tail}")
      end
      EXIT_OK
    end

    def newest_results(app_root)
      base = File.join(app_root, "tmp", "doubletrack")
      dir = Dir.glob(File.join(base, "*", "findings.json")).map { |f| File.dirname(f) }.max_by { |d| File.basename(d) }
      raise ConfigError, "no results found under #{base}: run `doubletrack run` first, or pass --results DIR" unless dir

      dir
    end

    def git_author(app_root)
      require "open3"
      name, = Open3.capture2("git", "-C", app_root, "config", "user.name", err: File::NULL)
      email, = Open3.capture2("git", "-C", app_root, "config", "user.email", err: File::NULL)
      name = name.strip
      return nil if name.empty?

      email.strip.empty? ? name : "#{name} <#{email.strip}>"
    rescue SystemCallError
      nil
    end

    def summarize(dir, run, findings)
      counts = run["counts"]
      coverage = run["coverage"]
      twins = run["twins"]
      fresh = findings.reject { |f| f["accepted"] }
      accepted = findings.size - fresh.size
      @out.puts("Doubletrack #{run["run_id"]}: #{run.dig("app", "name")}, " \
        "Rails #{twins.dig("control_a", "rails_version")} → #{twins.dig("candidate_b", "rails_version")}")
      @out.puts("  #{run["sessions"].size} sessions, #{run["sessions"].sum { |s| s["requests"] }} requests " \
        "replayed on control A, control A′ and candidate B")
      @out.puts("  Findings: #{counts["findings"]} new  (data-changing #{counts["data-changing"]}, " \
        "user-visible #{counts["user-visible"]}, cosmetic #{counts["cosmetic"]})" +
        (accepted.positive? ? ", #{accepted} accepted in #{File.basename(run.dig("baseline", "path").to_s)}" : ""))
      fresh.first(10).each do |f|
        @out.puts("    [#{f["severity"]}] #{f["title"]}  (#{f["sessions"]} session#{"s" unless f["sessions"] == 1}, #{f["id"]})")
      end
      @out.puts("    ... #{fresh.size - 10} more in the report") if fresh.size > 10
      stale = Array(run.dig("baseline", "stale"))
      @out.puts("  Baseline: #{stale.size} accepted finding#{"s" unless stale.size == 1} not seen in this run (stale): #{stale.join(", ")}") unless stale.empty?
      repros_path = File.join(dir, "repros.json")
      if File.exist?(repros_path)
        repros = JSON.parse(File.read(repros_path))
        list = repros["repros"]
        unless list.empty?
          verified = list.count { |r| r["status"] == "reproduced" }
          @out.puts("  Reproductions: #{verified} verified, #{list.size - verified} not verified " \
            "(#{repros["framework"]}, #{File.join(dir, Specgen.relative_dir(repros["framework"]))})")
        end
      end
      if (fidelity = run["capture_fidelity"])
        @out.puts("  Capture fidelity: #{fidelity["matched"]}/#{fidelity["requests"]} requests replayed with the status their test saw" +
          (fidelity["mismatches"].empty? ? "" : " (mismatches listed on the coverage page)"))
      end
      @out.puts("  Noise filtered: #{run.dig("noise", "suppressed")} " \
        "(#{run.dig("noise", "a_vs_a_prime_differences")} A/A′ differences observed)")
      @out.puts("  Route coverage: #{coverage["routes_hit"]} of #{coverage["routes_total"]} routes (#{(coverage["ratio"] * 100).round}%)")
      @out.puts("  Verdict: #{(run["verdict"] == "ready") ? "Ready to ship" : "Not ready to ship"}")
      @out.puts("  Report: #{File.join(dir, "report", "index.html")}")
      fresh.empty? ? EXIT_OK : EXIT_DIFFERENCES
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
                        [--baseline FILE] [--repro-framework auto|rspec|minitest]
        doubletrack report RESULTS_DIR
        doubletrack capture [APP_DIR] [--out FILE] [--command "bin/rails test test/integration"] [--gemfile FILE]
        doubletrack accept ID --reason TEXT [APP_DIR] [--author TEXT] [--results DIR] [--baseline FILE]

        Exit codes: 0 no new differences, 1 new differences found, 2 Doubletrack error.
      USAGE
    end
  end
end
