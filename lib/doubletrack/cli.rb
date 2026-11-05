# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../doubletrack"
require_relative "config"
require_relative "rails_label"

module Doubletrack
  # Command-line entry point. Commands that aren't built yet say so (and which later layer
  # delivers them, if one does) and exit 2, so nothing pretends to work.
  class CLI
    COMMANDS = {
      "init" => ["set up dual boot: write Gemfile.next for the next Rails (never edits Gemfile)", nil],
      "doctor" => ["check the setup and boot both Rails versions; says how to fix each problem", nil],
      "capture" => ["derive sessions from the app's request/integration tests", nil],
      "run" => ["replay sessions on control A, control A', and candidate B", nil],
      "report" => ["(re)generate findings and the static HTML report from stored results", nil],
      "accept" => ["mark a finding, or every finding of a change, as expected in doubletrack.baseline.yml", nil],
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
      when "run", "report", "accept", "capture", "init", "doctor"
        help = catch(:doubletrack_help) { return send(command, args) }
        @out.puts(help)
        EXIT_OK
      when *COMMANDS.keys
        planned = COMMANDS[command][1]
        when_built = (planned == "unscheduled") ? "not scheduled yet" : "planned for layer #{planned}"
        @err.puts("doubletrack #{command}: not implemented yet (#{when_built}; see docs/ROADMAP.md)")
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
    rescue => e
      # Never exit 1 here: 1 means "new differences found", and CI would read a crash as that.
      @err.puts("doubletrack #{command}: internal error: #{e.class}: #{e.message}")
      @err.puts("Please report this at https://github.com/JoshBlazer/doubletrack/issues (set DOUBLETRACK_DEBUG=1 for a backtrace).")
      @err.puts(Array(e.backtrace).first(15).join("\n")) if ENV["DOUBLETRACK_DEBUG"]
      EXIT_ERROR
    end

    private

    def run(args)
      options = {}
      overrides = {}
      parser = options_parser do |o|
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
      parser = options_parser do |o|
        o.banner = "Usage: doubletrack report RESULTS_DIR\n\n" \
          "Re-analyzes stored traces (picking up baseline changes) and rewrites findings, repros and the report.\n" \
          "Exit codes as for run: 0 no new differences, 1 new differences, 2 error."
      end
      dir, *extra = parser.parse(args)
      raise ConfigError, "usage: doubletrack report RESULTS_DIR" if dir.nil? || !extra.empty?

      dir = File.expand_path(dir)
      path = File.join(dir, "run.json")
      raise ConfigError, "#{path} not found (expected a results/<run_id> directory)" unless File.exist?(path)

      run = begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise ConfigError, "#{path} is not valid JSON (#{e.message.lines.first.to_s.strip[0, 120]})"
      end
      require_relative "results"
      run, findings = Results.analyze(dir, run)
      summarize(dir, run, findings)
    end

    def accept(args)
      options = {}
      parser = options_parser do |o|
        o.banner = "Usage: doubletrack accept ID --reason TEXT [APP_DIR] [options]"
        o.on("--reason TEXT", "why this difference is expected (required)") { |v| options[:reason] = v }
        o.on("--author TEXT", "who accepts it (default: git config user.name <user.email>)") { |v| options[:author] = v }
        o.on("--results DIR", "results directory with the finding (default: newest under APP_DIR/tmp/doubletrack)") { |v| options[:results] = File.expand_path(v) }
        o.on("--baseline FILE", "baseline file (default APP_DIR/doubletrack.baseline.yml)") { |v| options[:baseline] = File.expand_path(v) }
      end
      id, app_dir, *extra = parser.parse(args)
      raise ConfigError, "usage: doubletrack accept ID --reason TEXT [APP_DIR]" if id.nil? || !extra.empty?
      require_relative "baseline"
      change_id = CHANGE_ID.match?(id)
      unless change_id || Baseline::ID_PATTERN.match?(id)
        raise ConfigError, "#{id.inspect} is not a finding or change id (f- or c- and 12 hex digits, as shown in the report)"
      end
      raise ConfigError, "--reason TEXT is required: say why this difference is expected" if options[:reason].to_s.strip.empty?

      app_root = File.expand_path(app_dir || ".")
      results = options[:results] || newest_results(app_root)
      findings_path = File.join(results, "findings.json")
      raise ConfigError, "#{findings_path} not found: run `doubletrack run` first, or pass --results DIR" unless File.exist?(findings_path)

      stored = JSON.parse(File.read(findings_path))
      selected = if change_id
        change = Array(stored["changes"]).find { |c| c["id"] == id }
        raise ConfigError, "#{id} not found in #{findings_path} (change ids are listed on the report's findings page)" unless change

        stored["findings"].select { |f| change["findings"].include?(f["id"]) }
      else
        stored["findings"].select { |f| f["id"] == id }
      end
      raise ConfigError, "#{id} not found in #{findings_path} (finding ids are listed in the report)" if selected.empty?

      run = JSON.parse(File.read(File.join(results, "run.json")))
      author = options[:author] || git_author(app_root)
      raise ConfigError, "no author: pass --author TEXT, or set git config user.name in #{app_root}" if author.to_s.strip.empty?

      path = options[:baseline] || Config.load(app_root).baseline_path
      baseline = Baseline.load(path)
      outcomes = selected.map { |f| baseline.accept(f, reason: options[:reason], author: author, run: run) }
      baseline.write
      verb = outcomes.all?(:updated) ? "Updated" : "Accepted"
      if change_id
        @out.puts("#{verb} #{id} (#{selected.size} finding#{"s" unless selected.size == 1}) in #{path}")
        @out.puts("  #{change["path"]}: #{change["summary"]} [#{change["severity"]}]")
      else
        @out.puts("#{verb} #{id} in #{path}")
        @out.puts("  #{selected.first["title"]} [#{selected.first["severity"]}]")
      end
      @out.puts("  Commit #{File.basename(path)}; later runs list #{change_id ? "these findings" : "this finding"} as accepted and exit 0 if nothing else is new.")
      EXIT_OK
    end

    def init(args)
      options = {}
      parser = options_parser do |o|
        o.banner = "Usage: doubletrack init [APP_DIR] [options]"
        o.on("--to VERSION", "next Rails: 8.1, 8.1.2 or main (default: the next minor version)") { |v| options[:to] = v }
        o.on("--install", "run BUNDLE_GEMFILE=Gemfile.next bundle install afterwards") { options[:install] = true }
        o.on("--force", "replace an existing Gemfile.next and Gemfile.next.lock") { options[:force] = true }
      end
      app_dir, *extra = parser.parse(args)
      raise ConfigError, "usage: doubletrack init [APP_DIR] [--to VERSION] [--install]" unless extra.empty?

      require_relative "setup"
      Setup.init(app_dir || ".", out: @out, **options)
      EXIT_OK
    end

    def doctor(args)
      options = {boot: true}
      parser = options_parser do |o|
        o.banner = "Usage: doubletrack doctor [APP_DIR] [options]"
        o.on("--[no-]boot", "boot control A and candidate B (default: yes)") { |v| options[:boot] = v }
      end
      app_dir, *extra = parser.parse(args)
      raise ConfigError, "usage: doubletrack doctor [APP_DIR] [--no-boot]" unless extra.empty?

      require_relative "doctor"
      app_root = File.expand_path(app_dir || ".")
      Doctor.new(app_root, boot: options[:boot], config: Config.load(app_root)).report(@out)
    end

    def capture(args)
      options = {}
      parser = options_parser do |o|
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
      changes = stored_changes(dir).reject { |c| c["accepted"] }
      @out.puts("Doubletrack #{run["run_id"]}: #{run.dig("app", "name")}, " \
        "Rails #{RailsLabel.label(twins["control_a"])} → #{RailsLabel.label(twins["candidate_b"])}")
      @out.puts("  #{run["sessions"].size} sessions, #{run["sessions"].sum { |s| s["requests"] }} requests " \
        "replayed on control A, control A′ and candidate B")
      in_changes = fresh.any? ? " in #{changes.size} change#{"s" unless changes.size == 1}" : ""
      @out.puts("  Findings: #{counts["findings"]} new#{in_changes}  (data-changing #{counts["data-changing"]}, " \
        "user-visible #{counts["user-visible"]}, cosmetic #{counts["cosmetic"]})" +
        (accepted.positive? ? ", #{accepted} accepted in #{File.basename(run.dig("baseline", "path").to_s)}" : ""))
      changes.first(10).each do |c|
        routes = Array(c["routes"])
        where = (routes.size == 1) ? routes.first : "#{routes.size} routes"
        @out.puts("    [#{c["severity"]}] #{c["path"]}: #{c["summary"]}  (#{where}, #{c["id"]})")
        if (cause = Array(c["causes"]).first)
          @out.puts("      likely cause: #{cause["dependency"]} #{cause["ref"]} #{cause["text"]}")
        end
      end
      @out.puts("    ... #{changes.size - 10} more in the report") if changes.size > 10
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

    CHANGE_ID = /\Ac-\h{12}\z/

    def stored_changes(dir)
      path = File.join(dir, "findings.json")
      File.exist?(path) ? Array(JSON.parse(File.read(path))["changes"]) : []
    rescue JSON::ParserError
      []
    end

    # OptionParser's built-in --help calls `exit`; ours returns through #call instead.
    def options_parser
      OptionParser.new do |o|
        yield o
        o.on_tail("-h", "--help", "show this help") { throw :doubletrack_help, o.help }
      end
    end

    def usage
      lines = COMMANDS.map do |name, (summary, milestone)|
        format("  %-9s %s%s", name, summary, milestone ? " [#{milestone}]" : "")
      end
      <<~USAGE
        Usage: doubletrack COMMAND [options]

        Upgrade Rails with proof, not hope.

        Commands (not-yet-built ones are tagged with the later layer that delivers them, or "unscheduled"):
        #{lines.join("\n")}
          version   print the version

        doubletrack init [APP_DIR] [--to VERSION] [--install] [--force]
        doubletrack doctor [APP_DIR] [--no-boot]
        doubletrack run [APP_DIR] [--sessions DIR] [--out DIR] [--seed N] [--[no-]perform-jobs] [--[no-]seeds]
                        [--baseline FILE] [--repro-framework auto|rspec|minitest]
        doubletrack report RESULTS_DIR
        doubletrack capture [APP_DIR] [--out FILE] [--command "SCRIPT ARGS"] [--gemfile FILE]
        doubletrack accept ID --reason TEXT [APP_DIR] [--author TEXT] [--results DIR] [--baseline FILE]

        Exit codes (run and report): 0 no new differences, 1 new differences found, 2 Doubletrack error.
        doctor: 0 ready (warnings allowed), 1 a check failed, 2 error. Other commands exit 0 on success and 2 on error.
      USAGE
    end
  end
end
