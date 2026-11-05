# frozen_string_literal: true

require_relative "../rails_label"

module Doubletrack
  module Report
    # The run as GitHub-flavored Markdown, for job summaries and PR comments
    # (docs/design/action.md, ADR 0036). Readable without the HTML report.
    module Markdown
      MARKER = "<!-- doubletrack-summary -->"
      MAX_CHANGES = 25
      MAX_CELL = 60
      MAX_BUNDLE = 40
      EVIDENCE = {"commit" => "commit", "changelog" => "changelog", "source" => "source file"}.freeze

      module_function

      # @param run [Hash] run.json
      # @param findings [Array<Hash>]
      # @param changes [Array<Hash>]
      # @param repros [Hash{String=>Hash}] finding id => {"repro" => {"status"}}
      # @return [String]
      def call(run:, findings:, changes:, repros: {})
        counts = run["counts"] || {}
        fresh = changes.reject { |c| c["accepted"] }
        ready = run["verdict"] == "ready"
        lines = [MARKER]
        lines << "### Doubletrack: Rails #{RailsLabel.label(run.dig("twins", "control_a"))} → " \
                 "#{RailsLabel.label(run.dig("twins", "candidate_b"))}: #{ready ? "✅ Ready to ship" : "❌ Not ready to ship"}"
        lines << ""
        lines << "#{headline(counts)} · #{context(run)}"
        if fresh.any?
          lines << ""
          lines << "| Severity | Change | Where | Reproduced | Likely cause |"
          lines << "|---|---|---|---|---|"
          fresh.first(MAX_CHANGES).each { |c| lines << row(c, repros) }
          lines << "" << "…and #{fresh.size - MAX_CHANGES} more changes in the report." if fresh.size > MAX_CHANGES
          lines << ""
          lines << "If a change is expected: `doubletrack accept #{fresh.first["id"]} --reason \"...\"` " \
                   "(records it in `doubletrack.baseline.yml`; commit that file)."
        end
        deps = Array(run["dependency_changes"])
        if deps.any?
          lines << ""
          lines << "<details><summary>#{deps.size} bundle change#{"s" unless deps.size == 1}</summary>"
          lines << ""
          deps.first(MAX_BUNDLE).each { |d| lines << "- `#{d["name"]}` #{dependency_text(d)}" }
          lines << "- …and #{deps.size - MAX_BUNDLE} more" if deps.size > MAX_BUNDLE
          lines << ""
          lines << "</details>"
        end
        lines << ""
        lines << "<sub>Doubletrack #{run["doubletrack_version"]} · run #{run["run_id"]} · seed #{run["seed"]} · " \
                 "the full report is in this run's artifacts</sub>"
        lines.join("\n") + "\n"
      end

      def headline(counts)
        n = counts["findings"].to_i
        accepted = counts["accepted"].to_i
        tail = accepted.positive? ? ", #{accepted} accepted in the baseline" : ""
        if n.zero?
          "**No new findings**#{tail}"
        else
          c = counts["changes"].to_i
          "**#{n} new finding#{"s" unless n == 1} in #{c} change#{"s" unless c == 1}** " \
            "(data-changing #{counts["data-changing"].to_i}, user-visible #{counts["user-visible"].to_i}, cosmetic #{counts["cosmetic"].to_i})#{tail}"
        end
      end

      def context(run)
        sessions = Array(run["sessions"])
        requests = sessions.sum { |s| s["requests"].to_i }
        coverage = run["coverage"] || {}
        "#{requests} requests in #{sessions.size} session#{"s" unless sessions.size == 1} · " \
          "route coverage #{coverage["routes_hit"].to_i} of #{coverage["routes_total"].to_i} (#{(coverage["ratio"].to_f * 100).round}%) · " \
          "#{run.dig("noise", "suppressed").to_i} noisy differences filtered"
      end

      def row(change, repros)
        routes = Array(change["routes"])
        where = (routes.size == 1) ? "`#{cell(routes.first)}`" : "#{routes.size} routes"
        ids = Array(change["findings"])
        reproduced = ids.count { |id| repros.dig(id, "repro", "status") == "reproduced" }
        cause = Array(change["causes"]).first
        cause_text = cause ? "#{cell(cause["dependency"])} `#{cell(cause["ref"])}` (#{EVIDENCE.fetch(cause["evidence"], cause["evidence"])})" : "–"
        "| #{change["severity"]} | `#{cell(change["path"])}`: #{cell(change["summary"])} | #{where} | #{reproduced}/#{ids.size} | #{cause_text} |"
      end

      def cell(text)
        value = text.to_s.gsub(/\s*\n\s*/, " ")
        value = "#{value[0, MAX_CELL - 1]}…" if value.length > MAX_CELL
        value.gsub("|", "\\|").tr("`", "'")
      end

      def dependency_text(dep)
        if dep["from"].nil? then "added at #{dep["to"]}"
        elsif dep["to"].nil? then "removed (was #{dep["from"]})"
        else "#{dep["from"]} → #{dep["to"]}"
        end
      end
    end
  end
end
