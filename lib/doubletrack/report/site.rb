# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
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
      def initialize(run:, findings:, traces:)
        @run = run
        @findings = findings
        @traces = traces
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

      def grouped_findings
        Diff::Severity::ORDER.map { |sev| [sev, findings.select { |f| f["severity"] == sev }] }
      end

      def json(value)
        text = value.is_a?(String) ? value : JSON.pretty_generate(value)
        text = "#{text[0, MAX_VALUE_CHARS]}\n… (#{text.size - MAX_VALUE_CHARS} more characters)" if text.size > MAX_VALUE_CHARS
        h(text)
      end

      def scalar(value)
        value.nil? ? "(absent)" : json(value)
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
