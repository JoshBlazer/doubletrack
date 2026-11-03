# frozen_string_literal: true

module Doubletrack
  module Diff
    # Groups A-vs-B differences by fingerprint into findings
    # (docs/formats/findings.md).
    class Cluster
      MAX_OCCURRENCES = 20

      def initialize
        @findings = {}
      end

      # @param session_id [String]
      # @param request_index [Integer]
      # @param route_key [String]
      # @param difference [Difference]
      # @return [String] the finding id
      def add(session_id:, request_index:, route_key:, difference:)
        id = Fingerprint.call(route_key: route_key, difference: difference)
        path, op = Fingerprint.location(difference)
        finding = @findings[id] ||= {
          "id" => id,
          "severity" => Severity.classify(difference.path),
          "kind" => Fingerprint.kind(difference.path),
          "route" => route_key,
          "path" => path,
          "op" => op,
          "title" => "#{route_key}: #{path} #{op}",
          "sessions" => 0,
          "occurrences_total" => 0,
          "occurrences" => [],
          "_sessions" => {}
        }
        finding["_sessions"][session_id] = true
        finding["occurrences_total"] += 1
        if finding["occurrences"].size < MAX_OCCURRENCES
          finding["occurrences"] << {"session_id" => session_id, "request_index" => request_index,
                                     "path" => difference.path_string, "a" => difference.a, "b" => difference.b}
        end
        id
      end

      # @return [Array<Hash>] sorted by severity, route, path
      def findings
        @findings.values.map do |f|
          f.except("_sessions").merge("sessions" => f["_sessions"].size)
        end.sort_by { |f| [Severity::ORDER.index(f["severity"]), f["route"], f["path"], f["id"]] }
      end
    end
  end
end
