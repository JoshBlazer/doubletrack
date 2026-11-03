# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "shellwords"
require_relative "../diff"

module Doubletrack
  module Report
    # Writes the static report: overview, findings, one page per finding, coverage, noise.
    # Pure output: everything shown comes from run.json, findings.json and the stored traces.
    # No network, no CDN, no fonts; JS only enhances (filters, copy buttons).
    class Site
      TEMPLATES = File.expand_path("templates", __dir__)
      ASSETS = File.expand_path("assets", __dir__)
      SEVERITY_LABELS = {"data-changing" => "Data-changing", "user-visible" => "User-visible", "cosmetic" => "Cosmetic"}.freeze
      CHANNELS = %w[sql_writes jobs mail cache http performed_jobs].freeze
      MAX_VALUE_CHARS = 4000
      NAV = [["index.html", "Overview"], ["findings.html", "Findings"], ["coverage.html", "Coverage"], ["noise.html", "Noise"]].freeze

      include ERB::Util

      # @param run [Hash] run.json
      # @param findings [Array<Hash>] findings.json "findings"
      # @param traces [#call] (session_id, role) -> Array of raw traces
      # @param repros [Hash{String=>Hash}] finding id => {"repro", "file", "source", "framework", "snapshot"}
      def initialize(run:, findings:, traces:, repros: {})
        @run = run
        @findings = findings
        @traces = traces
        @repros = repros
        @cache = {}
      end

      # @param dir [String] output directory (created; existing pages are replaced)
      def write(dir)
        FileUtils.mkdir_p(File.join(dir, "findings"))
        Dir.glob(File.join(dir, "findings", "*.html")).each { |f| FileUtils.rm_f(f) }
        %w[style.css enhance.js].each { |asset| FileUtils.cp(File.join(ASSETS, asset), File.join(dir, asset)) }
        page(dir, "index.html", "Overview", "index")
        page(dir, "findings.html", "Findings", "findings")
        page(dir, "coverage.html", "Coverage", "coverage")
        page(dir, "noise.html", "Noise", "noise")
        @findings.each do |finding|
          @finding = finding
          page(dir, "findings/#{finding["id"]}.html", finding["title"], "finding", depth: 1)
        end
        dir
      end

      private

      attr_reader :run, :findings

      def page(dir, name, title, template, depth: 0)
        @title = title
        @root = "../" * depth
        @current = name
        body = render(template)
        html = render("layout") { body }
        File.write(File.join(dir, name), html)
      end

      def render(name)
        ERB.new(File.read(File.join(TEMPLATES, "#{name}.html.erb")), trim_mode: "-").result(binding)
      end

      # --- helpers used by templates -------------------------------------------------

      def verdict_ready? = run["verdict"] == "ready"

      def count(severity) = run.dig("counts", severity).to_i

      def badge(severity)
        %(<span class="badge badge-#{h(severity)}">#{h(SEVERITY_LABELS.fetch(severity, severity))}</span>)
      end

      def finding_href(finding) = "#{@root}findings/#{finding["id"]}.html"

      def pct(ratio) = "#{(ratio.to_f * 100).round}%"

      def twin_version(role) = run.dig("twins", role, "rails_version").to_s

      def requests_total = Array(run["sessions"]).sum { |s| s["requests"].to_i }

      # Findings not in the baseline; they decide the verdict (ADR 0024).
      def new_findings = findings.reject { |f| f["accepted"] }

      def accepted_findings = findings.select { |f| f["accepted"] }

      def stale_ids = Array(run.dig("baseline", "stale"))

      def baseline_name = File.basename(run.dig("baseline", "path") || "doubletrack.baseline.yml")

      def grouped_findings
        Diff::Severity::ORDER.map { |sev| [sev, new_findings.select { |f| f["severity"] == sev }] }
      end

      def repro_for(finding) = @repros[finding["id"]]

      def repro_value(encoded)
        return "(not observed)" unless encoded

        encoded["absent"] ? "(absent)" : value_text(encoded["value"])
      end

      def repro_run_commands(info)
        file = info["file"]
        if info["framework"] == "rspec"
          ["bundle exec rspec #{shell(results_path(file))}", "BUNDLE_GEMFILE=#{shell(next_gemfile)} bundle exec rspec #{shell(results_path(file))}"]
        else
          ["bundle exec ruby -Itest #{shell(results_path(file))}", "BUNDLE_GEMFILE=#{shell(next_gemfile)} bundle exec ruby -Itest #{shell(results_path(file))}"]
        end
      end

      def repro_copy_command(info)
        dest = (info["framework"] == "rspec") ? "spec/doubletrack" : "test/doubletrack"
        "mkdir -p #{dest}/snapshots && cp #{shell(results_path(info["file"]))} #{dest}/ && cp #{shell(results_path(info["snapshot"]))} #{dest}/snapshots/"
      end

      def shell(text) = Shellwords.escape(text.to_s)

      # A path inside the results directory, relative to the app root when the results live there.
      def results_path(relative)
        dir = run["results_dir"].to_s
        root = run.dig("app", "root").to_s
        full = dir.empty? ? relative : File.join(dir, relative)
        (!root.empty? && full.start_with?("#{root}/")) ? full.delete_prefix("#{root}/") : full
      end

      def next_gemfile = File.basename(run.dig("twins", "candidate_b", "bundle_gemfile").to_s.then { |g| g.empty? ? "Gemfile.next" : g })

      def json(value)
        text = value.is_a?(String) ? value : JSON.pretty_generate(value)
        text = "#{text[0, MAX_VALUE_CHARS]}\n… (#{text.size - MAX_VALUE_CHARS} more characters)" if text.size > MAX_VALUE_CHARS
        h(text)
      end

      # One side of a difference. Values are shown as JSON, so "1" and 1 look different
      # and null is "null"; "(absent)" only marks the side an added/removed path is missing on.
      def side(occurrence, key)
        missing = (key == "a" && occurrence["op"] == "added") || (key == "b" && occurrence["op"] == "removed")
        missing ? "(absent)" : value_text(occurrence[key])
      end

      def value_text(value)
        json(JSON.pretty_generate(value))
      rescue JSON::GeneratorError
        json(value.inspect)
      end

      def traces_for(session_id, role)
        @cache[[session_id, role]] ||= @traces.call(session_id, role)
      end

      def normalized(trace)
        Normalize::Trace.call(trace, session_cookie: run.dig("twins", "control_a", "session_cookie"),
          ignored_headers: run.dig("options", "ignored_headers") || [], ignored_columns: run.dig("options", "ignored_columns") || [])
      end

      def status_of(trace)
        trace["response"] ? trace.dig("response", "status").to_s : "raised #{trace.dig("exception", "class")}"
      end

      def request_line(trace)
        "#{trace.dig("request", "method")} #{trace.dig("request", "path")}"
      end

      # Side-by-side sections for one request: [label, a_value, b_value, differs?]
      def sections(a, b)
        na = normalized(a)
        nb = normalized(b)
        rows = [["Response", na["response"] || {"exception" => na["exception"]}, nb["response"] || {"exception" => nb["exception"]}],
          ["Session", na["session"], nb["session"]]]
        CHANNELS.each { |c| rows << [c.tr("_", " ").capitalize, na[c], nb[c]] }
        rows.map { |label, x, y| [label, x, y, x != y] }
      end

      def deprecations(trace)
        Array(trace["deprecations"]).map { |d| d["message"] }.uniq
      end

      def masked_paths_for(route) = Array(run.dig("noise", "masked_paths", route))

      def accept_command(finding) = %(doubletrack accept #{finding["id"]} --reason "...")
    end
  end
end
