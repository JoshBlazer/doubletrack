# frozen_string_literal: true

module Doubletrack
  module Diff
    # The whole analysis over raw traces: normalize → A/A′ noise mask → A/B diff minus
    # mask → fingerprint → cluster → severity, plus route coverage
    # (docs/design/diff.md#pipeline).
    class Analyzer
      ROLES = %w[control_a control_a_prime candidate_b].freeze

      # @param routes [Array<Hash>] from hello (verb, path, controller, action)
      # @param session_cookie [String, nil]
      # @param ignored_headers [Array<String>]
      # @param ignored_columns [Array<String>]
      def initialize(routes:, session_cookie:, ignored_headers: [], ignored_columns: [])
        @routes = Array(routes)
        @normalize_options = {session_cookie: session_cookie, ignored_headers: ignored_headers, ignored_columns: ignored_columns}
      end

      # @param sessions [Array<Hash>] [{"id", "traces" => {role => [raw trace, ...]}}]
      # @return [Hash] {findings:, noise:, coverage:, per_session:}
      def call(sessions)
        mask = NoiseMask.new
        prepared = sessions.map { |s| prepare(s) }

        prepared.each do |s|
          s[:a].zip(s[:a_prime]).each_with_index do |(a, ap), i|
            mask.add(s[:route_keys][i], Structural.call(a, ap))
          end
        end

        cluster = Cluster.new
        a_vs_b = 0
        suppressed = 0
        per_session = prepared.map do |s|
          ids = {}
          s[:a].zip(s[:b]).each_with_index do |(a, b), i|
            route_key = s[:route_keys][i]
            Structural.call(a, b).each do |difference|
              a_vs_b += 1
              if mask.masked?(route_key, difference.path)
                suppressed += 1
                next
              end
              ids[cluster.add(session_id: s[:id], request_index: i, route_key: route_key, difference: difference)] = true
            end
          end
          {"id" => s[:id], "requests" => s[:a].size, "findings" => ids.size}
        end

        {
          findings: cluster.findings,
          noise: {"a_vs_a_prime_differences" => mask.observed, "a_vs_b_differences" => a_vs_b,
                  "suppressed" => suppressed, "masked_paths" => mask.to_h},
          coverage: coverage(sessions),
          per_session: per_session
        }
      end

      # "VERB pattern" from the trace's route, or "UNROUTED METHOD /path" (no query).
      def self.route_key(trace)
        route = trace["route"]
        if route && route["path"]
          "#{route["verb"]} #{route["path"]}"
        else
          request = trace["request"] || {}
          "UNROUTED #{request["method"]} #{request["path"].to_s.split("?").first}"
        end
      end

      private

      def prepare(session)
        traces = session.fetch("traces")
        sizes = ROLES.map { |r| Array(traces[r]).size }
        unless sizes.uniq.size == 1
          raise Error, "session #{session["id"]}: twins returned different numbers of traces (#{ROLES.zip(sizes).map { |r, n| "#{r}=#{n}" }.join(", ")})"
        end

        normalized = ROLES.to_h { |r| [r, traces[r].map { |t| Normalize::Trace.call(t, **@normalize_options) }] }
        {
          id: session["id"],
          a: normalized["control_a"], a_prime: normalized["control_a_prime"], b: normalized["candidate_b"],
          route_keys: traces["control_a"].map { |t| self.class.route_key(t) }
        }
      end

      # A route is hit if control A or candidate B recorded it; hits counts A's requests.
      def coverage(sessions)
        hits = Hash.new(0)
        seen = {}
        sessions.each do |s|
          %w[control_a candidate_b].each do |role|
            Array(s["traces"][role]).each do |t|
              route = t["route"]
              next unless route && route["path"]

              key = "#{route["verb"]} #{route["path"]}"
              seen[key] = true
              hits[key] += 1 if role == "control_a"
            end
          end
        end
        routes = @routes.map do |r|
          key = "#{r["verb"]} #{r["path"]}"
          r.slice("verb", "path", "controller", "action").merge("hits" => hits[key], "hit" => seen.key?(key))
        end
        total = routes.size
        hit = routes.count { |r| r["hit"] }
        {"routes_total" => total, "routes_hit" => hit, "ratio" => total.zero? ? 0.0 : hit.fdiv(total), "routes" => routes}
      end
    end
  end
end
