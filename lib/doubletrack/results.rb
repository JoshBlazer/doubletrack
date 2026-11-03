# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "version"
require_relative "diff"
require_relative "baseline"
require_relative "specgen"
require_relative "report"

module Doubletrack
  # The results directory of one run (docs/formats/run.md, docs/formats/findings.md):
  # raw traces in, analysis + findings + report out. `doubletrack report` re-runs
  # {.analyze} on stored traces without any twins.
  module Results
    ROLES = Diff::Analyzer::ROLES
    FINDINGS_VERSION = 1

    module_function

    def trace_path(dir, session_id, role)
      File.join(dir, "traces", session_id, "#{role}.json")
    end

    def write_traces(dir, session_id, role, traces)
      path = trace_path(dir, session_id, role)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(traces) + "\n")
    end

    def read_traces(dir, session_id, role)
      JSON.parse(File.read(trace_path(dir, session_id, role)))
    rescue Errno::ENOENT
      raise Error, "missing traces for session #{session_id.inspect} (#{role}) in #{dir}"
    end

    # Analyzes stored traces and writes findings.json, run.json, the reproduction files
    # (from repros.json, if the run made any) and the report.
    # @param dir [String] results/<run_id>
    # @param run [Hash] run.json content (analysis fields are filled in)
    # @param repros [Hash, nil] repros.json content; read from dir when nil
    # @return [Array(Hash, Array<Hash>)] [run, findings]
    def analyze(dir, run, repros: nil)
      run, findings = compute(dir, run)
      write(dir, run, findings, repros || load_repros(dir))
      [run, findings]
    end

    # The analysis and the baseline, without writing anything.
    # @return [Array(Hash, Array<Hash>)] [run, findings]
    # @raise [ConfigError] malformed baseline
    def compute(dir, run)
      started = monotonic
      options = run.fetch("options", {})
      analyzer = Diff::Analyzer.new(
        routes: run.fetch("routes", []),
        session_cookie: run.dig("twins", "control_a", "session_cookie"),
        ignored_headers: options.fetch("ignored_headers", []),
        ignored_columns: options.fetch("ignored_columns", [])
      )
      sessions = run.fetch("sessions").map do |s|
        {"id" => s["id"], "traces" => ROLES.to_h { |r| [r, read_traces(dir, s["id"], r)] }}
      end
      result = analyzer.call(sessions)
      baseline_path = run.dig("baseline", "path") || File.join(run.dig("app", "root").to_s, Baseline::FILE)
      baseline = Baseline.load(baseline_path)
      findings, stale = baseline.apply(result[:findings].map { |f| with_trace_pointers(f) })

      fresh = findings.reject { |f| f["accepted"] }
      counts = Diff::Severity::ORDER.to_h { |sev| [sev, fresh.count { |f| f["severity"] == sev }] }
      run = run.merge(
        "sessions" => result[:per_session],
        "coverage" => result[:coverage],
        "noise" => result[:noise],
        "counts" => {"findings" => fresh.size}.merge(counts).merge("accepted" => findings.size - fresh.size),
        "baseline" => {"path" => baseline_path, "exists" => baseline.exist?, "accepted" => findings.size - fresh.size,
                       "stale" => stale},
        "verdict" => (counts["data-changing"] + counts["user-visible"]).zero? ? "ready" : "not_ready"
      )
      run["timings"] = run.fetch("timings", {}).merge("analysis_s" => (monotonic - started).round(2))
      [run, findings]
    end

    # Writes findings.json, run.json, repros.json + spec files, and the report.
    def write(dir, run, findings, repros)
      report_started = monotonic
      accepted = findings.select { |f| f["accepted"] }.to_set { |f| f["id"] }
      rendered = repros ? render_repros(dir, run, repros, skip: accepted) : {}
      traces = ->(session_id, role) { read_traces(dir, session_id, role) }
      Report::Site.new(run: run.merge("results_dir" => dir), findings: findings, traces: traces, repros: rendered).write(File.join(dir, "report"))
      run["timings"]["report_s"] = (monotonic - report_started).round(2)

      File.write(File.join(dir, "findings.json"),
        JSON.pretty_generate("findings_version" => FINDINGS_VERSION, "run_id" => run["run_id"], "findings" => findings) + "\n")
      File.write(File.join(dir, "repros.json"), JSON.pretty_generate(repros) + "\n") if repros
      File.write(File.join(dir, "run.json"), JSON.pretty_generate(run) + "\n")
    end

    def load_repros(dir)
      path = File.join(dir, "repros.json")
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    end

    # Renders every repro to its spec file (docs/formats/repros.md).
    # @return [Hash{String=>Hash}] finding id => {"repro", "file", "source"}
    def render_repros(dir, run, repros, skip: Set.new)
      framework = repros.fetch("framework")
      relative = Specgen.relative_dir(framework)
      target = File.join(dir, relative)
      FileUtils.mkdir_p(target)
      Dir.glob(File.join(target, "*_{spec,test}.rb")).each { |f| FileUtils.rm_f(f) }
      writer = Specgen::Writer.new(
        framework: framework, run_id: run["run_id"],
        from: run.dig("twins", "control_a", "rails_version").to_s, to: run.dig("twins", "candidate_b", "rails_version").to_s,
        gemfile: File.basename(run.dig("twins", "control_a", "bundle_gemfile").to_s),
        next_gemfile: File.basename(run.dig("twins", "candidate_b", "bundle_gemfile").to_s),
        snapshot: repros["snapshot"], doubletrack_version: VERSION
      )
      repros.fetch("repros").reject { |r| skip.include?(r["finding_id"]) }.to_h do |repro|
        next [repro["finding_id"], {"repro" => repro, "framework" => framework}] if repro["status"] == "error"

        file = File.join(relative, Specgen.file_name(framework, repro["finding_id"]))
        repro["file"] = file
        source = writer.render(repro)
        File.write(File.join(dir, file), source)
        [repro["finding_id"], {"repro" => repro, "file" => file, "source" => source, "framework" => framework,
                               "snapshot" => File.join(relative, repro["snapshot"] || repros["snapshot"])}]
      end
    end

    def with_trace_pointers(finding)
      finding.merge("occurrences" => finding["occurrences"].map do |o|
        o.merge("traces" => {"control_a" => "traces/#{o["session_id"]}/control_a.json",
                             "candidate_b" => "traces/#{o["session_id"]}/candidate_b.json"})
      end)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
