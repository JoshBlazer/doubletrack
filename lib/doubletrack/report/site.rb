# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "shellwords"
require_relative "../diff"
require_relative "../specgen/writer"
require_relative "describe"
require_relative "line_diff"

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
      SECTION_LABELS = {"sql_writes" => "SQL writes", "jobs" => "Enqueued jobs", "mail" => "Mail", "cache" => "Cache writes",
                        "http" => "Outbound HTTP", "performed_jobs" => "Performed jobs"}.freeze
      MAX_DIFF_LINES = 600
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

      # True when two strings differ only in spaces, tabs or newlines, which is nearly
      # invisible in the table.
      def whitespace_only?(occurrence)
        a = occurrence["a"]
        b = occurrence["b"]
        a.is_a?(String) && b.is_a?(String) && a != b && a.gsub(/\s+/, " ").strip == b.gsub(/\s+/, " ").strip
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
        CHANNELS.each { |c| rows << [SECTION_LABELS.fetch(c), na[c], nb[c]] }
        rows.map { |label, x, y| [label, x, y, x != y] }
      end

      def deprecations(trace)
        Array(trace["deprecations"]).map { |d| d["message"] }.uniq
      end

      def masked_paths_for(route) = Array(run.dig("noise", "masked_paths", route))

      # The command targets the baseline and results this report came from, when they
      # aren't the defaults `accept` would find on its own.
      def accept_command(finding)
        root = run.dig("app", "root").to_s
        command = %(doubletrack accept #{finding["id"]} --reason "...")
        dir = run["results_dir"].to_s
        command += " --results #{shell(dir)}" unless dir.empty? || dir.start_with?(File.join(root, "tmp", "doubletrack") + "/")
        path = run.dig("baseline", "path").to_s
        command += " --baseline #{shell(path)}" unless path.empty? || path == File.join(root, "doubletrack.baseline.yml")
        command
      end

      # "JSON response field total changed", capitalized, for a finding.
      def plain(finding)
        text = Describe.sentence(finding["path"], finding["op"], to: twin_version("candidate_b"))
        text[0].upcase + text[1..]
      end

      def verdict_counts
        n = new_findings.size
        "#{n} new finding#{"s" unless n == 1}: " +
          Diff::Severity::ORDER.map { |sev| "#{count(sev)} #{sev}" }.join(", ") + "."
      end

      # @return [String] the finding's reproduction status, for the findings table
      def repro_status(finding)
        return "accepted" if finding["accepted"]

        case repro_for(finding)&.dig("repro", "status")
        when "reproduced" then "verified"
        when "not_reproduced" then "not verified"
        when "error" then "error"
        else "not generated"
        end
      end

      def repro_requests_text(repro)
        kept = repro["requests"].size
        before = repro["requests_before"] || kept
        text = "#{kept} request#{"s" unless kept == 1}"
        (kept < before) ? "#{text} (minimized from #{before})" : "#{text} (none of the earlier ones could be dropped)"
      end

      def gem_line = Specgen::Writer::GEM_LINE

      # Both panels of a section, escaped, with the lines that differ marked (− old,
      # + new) and long unchanged stretches folded. Identical values are shown whole.
      # @return [Array(String, String)]
      def diff_panes(x, y)
        a = (x.is_a?(String) ? x : JSON.pretty_generate(x)).lines(chomp: true)
        b = (y.is_a?(String) ? y : JSON.pretty_generate(y)).lines(chomp: true)
        return [json(x), json(y)] if a == b

        ops = LineDiff.fold(LineDiff.ops(a, b))
        [pane(ops, :del), pane(ops, :ins)]
      rescue JSON::GeneratorError
        [json(x), json(y)]
      end

      def pane(ops, mine)
        lines = []
        ops.each do |op, value|
          case op
          when :eq then lines << %(<span class="gutter" aria-hidden="true"> </span>#{h(value)})
          when :skip then lines << %(<span class="fold">⋯ #{value} unchanged line#{"s" unless value == 1}</span>)
          when mine
            tag = (mine == :del) ? "del" : "ins"
            mark = (mine == :del) ? "−" : "+"
            lines << %(<#{tag}><span class="gutter" aria-hidden="true">#{mark}</span>#{h(value)}</#{tag}>)
          end
        end
        if lines.size > MAX_DIFF_LINES
          rest = lines.size - MAX_DIFF_LINES
          lines = lines.first(MAX_DIFF_LINES) << %(<span class="fold">… #{rest} more line#{"s" unless rest == 1} not shown (full traces are in the results directory)</span>)
        end
        lines.join("\n")
      end
    end
  end
end
