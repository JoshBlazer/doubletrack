# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "diff"
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

    # Analyzes stored traces and writes findings.json, run.json and the report.
    # @param dir [String] results/<run_id>
    # @param run [Hash] run.json content (analysis fields are filled in)
    # @return [Array(Hash, Array<Hash>)] [run, findings]
    def analyze(dir, run)
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
      findings = result[:findings].map { |f| with_trace_pointers(f) }

      counts = Diff::Severity::ORDER.to_h { |sev| [sev, findings.count { |f| f["severity"] == sev }] }
      run = run.merge(
        "sessions" => result[:per_session],
        "coverage" => result[:coverage],
        "noise" => result[:noise],
        "counts" => {"findings" => findings.size}.merge(counts),
        "verdict" => (counts["data-changing"] + counts["user-visible"]).zero? ? "ready" : "not_ready"
      )
      run["timings"] = run.fetch("timings", {}).merge("analysis_s" => (monotonic - started).round(2))

      report_started = monotonic
      traces = ->(session_id, role) { read_traces(dir, session_id, role) }
      Report::Site.new(run: run, findings: findings, traces: traces).write(File.join(dir, "report"))
      run["timings"]["report_s"] = (monotonic - report_started).round(2)

      File.write(File.join(dir, "findings.json"),
        JSON.pretty_generate("findings_version" => FINDINGS_VERSION, "run_id" => run["run_id"], "findings" => findings) + "\n")
      File.write(File.join(dir, "run.json"), JSON.pretty_generate(run) + "\n")
      [run, findings]
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
