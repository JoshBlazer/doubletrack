# frozen_string_literal: true

require "digest"
require "json"

module Doubletrack
  module Diff
    # Groups findings that are the same change on different routes (ADR 0031,
    # docs/design/changes.md).
    module Changes
      MAX_LISTED = 3

      module_function

      # @param findings [Array<Hash>] clustered findings, with occurrences; each gets "change_id"
      # @return [Array<Hash>] changes, most severe and largest first
      def call(findings)
        groups = findings.group_by { |f| key(f) }
        changes = groups.map do |(kind, path, op, delta), members|
          id = "c-#{Digest::SHA256.hexdigest(JSON.generate([kind, path, op, delta]))[0, 12]}"
          members.each { |f| f["change_id"] = id }
          members = members.sort_by { |f| [f["route"].to_s, f["id"]] }
          first = members.first["occurrences"].to_a.first || {}
          {
            "id" => id,
            "severity" => Severity.max(members.map { |f| f["severity"] }),
            "kind" => kind,
            "path" => path,
            "op" => op,
            "summary" => summary(delta, path, first),
            "delta" => delta,
            "added_runs" => (first["a"].is_a?(String) || first["b"].is_a?(String)) ? Delta.added_runs(first["a"], first["b"]) : [],
            "findings" => members.map { |f| f["id"] },
            "routes" => members.map { |f| f["route"] }.uniq,
            "sessions" => members.sum { |f| f["sessions"].to_i },
            "occurrences_total" => members.sum { |f| f["occurrences_total"].to_i },
            "accepted" => members.all? { |f| f["accepted"] },
            "causes" => []
          }
        end
        changes.sort_by { |c| [Severity::ORDER.index(c["severity"]), -c["findings"].size, c["path"], c["id"]] }
      end

      # [kind, path, op, sorted unique occurrence deltas]
      def key(finding)
        deltas = finding["occurrences"].to_a.map do |o|
          segments = o["segments"] || []
          Delta.call(segments, o["a"], o["b"])
        end
        [finding["kind"], finding["path"], finding["op"], deltas.uniq.sort_by { |d| JSON.generate(d) }]
      end

      # @return [String] "adds X-Requested-With", "200 → 500", "changed"
      def summary(deltas, path, example = {})
        return "changed" if path == "response.body.html" || deltas.size != 1

        d = deltas.first
        if d.key?("added") && d["added"].size + d["removed"].size > MAX_LISTED
          "#{quoted(example["a"])} → #{quoted(example["b"])}"
        elsif d.key?("added")
          parts = []
          parts << "adds #{listed(d["added"])}" if d["added"].any?
          parts << "removes #{listed(d["removed"])}" if d["removed"].any?
          parts.join("; ")
        else
          "#{display(d["from"])} → #{display(d["to"])}"
        end
      end

      MAX_QUOTED = 60

      def quoted(value)
        return "(none)" if value.nil?

        text = value.to_s
        text = "#{text[0, MAX_QUOTED - 1]}…" if text.length > MAX_QUOTED
        text.inspect
      end

      def listed(tokens)
        return tokens.join(", ") if tokens.size <= MAX_LISTED

        "#{tokens.first(MAX_LISTED).join(", ")} and #{tokens.size - MAX_LISTED} more"
      end

      def display(value)
        value.is_a?(String) ? value : JSON.generate(value)
      end
    end
  end
end
