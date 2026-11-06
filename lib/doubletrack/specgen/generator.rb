# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "../twin/postgres_snapshot"
require_relative "../normalize/trace"
require_relative "../coordinator/parallel"

module Doubletrack
  module Specgen
    # Builds a verified, minimized reproduction for each new finding, using the run's
    # booted twins (ADR 0023). Produces the repros.json content; Results renders the files.
    class Generator
      REPROS_VERSION = 1
      ROLES = Repro::ROLES

      # @param twins [Hash{String=>Coordinator::TwinProcess}] control_a, control_a_prime, candidate_b
      # @param sessions [Array<Session>]
      # @param run_seed [Integer]
      # @param snapshot_paths [Hash{String=>String}] snapshot kind => the run's template
      # @param normalize [Hash] {session_cookie:, ignored_headers:, ignored_columns:}
      # @param perform_jobs [Boolean]
      # @param framework [String] "rspec" or "minitest"
      # @param dir [String] results/<run_id>
      # @param progress [IO]
      def initialize(twins:, sessions:, run_seed:, snapshot_paths:, normalize:, perform_jobs:, framework:, dir:, progress: $stderr)
        @twins = twins
        @sessions = sessions.to_h { |s| [s.id, s] }
        @run_seed = run_seed
        @snapshot_paths = snapshot_paths
        @copied = {}
        @normalize = normalize
        @perform_jobs = perform_jobs
        @framework = framework
        @dir = dir
        @progress = progress
      end

      # @param findings [Array<Hash>] analyzed findings (accepted ones are skipped)
      # @param run_id [String]
      # @return [Hash] repros.json content
      def call(findings, run_id:)
        fresh = findings.reject { |f| f["accepted"] }
        repros = fresh.each_with_index.map do |finding, i|
          @progress.puts("  reproduction #{i + 1}/#{fresh.size}: #{finding["id"]}")
          build(finding)
        end
        {"repros_version" => REPROS_VERSION, "run_id" => run_id, "framework" => @framework, "repros" => repros}
      end

      private

      def build(finding)
        occurrence = finding["occurrences"].min_by { |o| o["request_index"] }
        session = @sessions.fetch(occurrence["session_id"])
        template = @snapshot_paths.fetch(session.snapshot)
        payload = session.to_payload(run_seed: @run_seed, snapshot: template)
        prefix = payload["requests"][0..occurrence["request_index"]]
        segments = occurrence["segments"]
        absent = occurrence["op"] == "added"
        expected = absent ? Repro::ABSENT : occurrence["a"]

        replay = ->(requests) { observe(payload.merge("requests" => requests), segments) }
        outcome = Minimizer.new(replay: replay).call(requests: prefix, expected: expected)
        {
          "finding_id" => finding["id"],
          "title" => finding["title"],
          "severity" => finding["severity"],
          "session_id" => session.id,
          "snapshot" => copy_snapshot(template),
          "seed" => payload["seed"],
          "started_at" => payload["started_at"],
          "perform_jobs" => @perform_jobs,
          "http_stubs" => payload["http_stubs"],
          "requests" => outcome.requests,
          "kept_request_indexes" => outcome.kept,
          "requests_before" => prefix.size,
          "segments" => segments,
          "op" => occurrence["op"] || finding["op"],
          "expected" => absent ? nil : expected,
          "expected_absent" => absent,
          "normalize" => {"ignored_headers" => @normalize[:ignored_headers], "ignored_columns" => @normalize[:ignored_columns]},
          "status" => outcome.status,
          "observed" => outcome.observed.transform_values { |v| Repro.encode_observed(v) }
        }
      rescue => e
        # One repro failing (a twin error, or a bug here) must not cost the whole run.
        message = e.is_a?(Doubletrack::Error) ? e.message : "#{e.class}: #{e.message}"
        {"finding_id" => finding["id"], "title" => finding["title"], "severity" => finding["severity"],
         "status" => "error", "error" => message}
      end

      # Copies a template next to the spec files once; returns its path relative to them.
      def copy_snapshot(template)
        @copied[template] ||= begin
          extension = Twin::PostgresSnapshot.recipe(template) ? "pg.json" : "sqlite3" # ADR 0037
          relative = "snapshots/#{Digest::SHA256.file(template).hexdigest[0, 12]}.#{extension}"
          target = File.join(@dir, Specgen.relative_dir(@framework), relative)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(template, target)
          relative
        end
      end

      # Replays on A, A′ and B concurrently; returns role => value at segments in the last trace.
      def observe(session, segments)
        options = {"perform_jobs" => @perform_jobs}
        results = Coordinator.parallel_map(ROLES) { |role| @twins.fetch(role).run_session(session, options) }
        ROLES.zip(results).to_h do |role, result|
          trace = Normalize::Trace.call(result.fetch("traces").last, **@normalize)
          [role, Repro.lookup(trace, segments)]
        end
      end
    end
  end
end
