# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "version"
require_relative "errors"
require_relative "protocol"
require_relative "coordinator/twin_process"
require_relative "normalize/trace"

module Doubletrack
  # The helper that generated reproduction specs call (docs/design/specgen.md, ADR 0022).
  # It runs inside the user's test process, under the app's own bundle:
  #
  #   replay = Doubletrack::Repro.replay(snapshot: ..., requests: [...], started_at: ..., seed: ...)
  #   replay.last.at("exception", "message")  # => value, or Doubletrack::Repro::ABSENT
  #
  # The requests are replayed in a twin process of the app (same entry point, overlay,
  # clock, seeding, HTTP interception and recorder as `doubletrack run`) booted on the
  # Gemfile of the current `bundle exec`. One twin per Gemfile is shared by every repro in
  # the process and stopped at exit. The test process itself never boots Rails.
  #
  # {.lookup} and {.reproduces?} are also what `doubletrack run` uses to verify repros, so
  # "verified in the run" and "the spec passes" mean the same check.
  module Repro
    # A path that doesn't exist in the trace. Distinct from nil (a JSON null).
    ABSENT = Object.new.tap do |absent|
      def absent.inspect = "<absent>"

      def absent.to_s = "<absent>"
    end.freeze

    ROLES = %w[control_a control_a_prime candidate_b].freeze

    # One normalized trace.
    class Trace
      def initialize(hash)
        @hash = hash
      end

      # @param segments [Array<String, Integer>] hash keys and array indexes
      # @return [Object] the value, or {ABSENT}
      def at(*segments) = Repro.lookup(@hash, segments)

      def to_h = @hash

      def inspect = "#<Doubletrack::Repro::Trace #{@hash.inspect}>"
    end

    # The normalized traces of a replayed session, one per request.
    class Result
      include Enumerable

      attr_reader :rails_version

      def initialize(traces:, rails_version: nil)
        @traces = traces.map { |t| Trace.new(t) }
        @rails_version = rails_version
      end

      def each(&) = @traces.each(&)

      def [](index) = @traces[index]

      def last = @traces.last

      def size = @traces.size
    end

    module_function

    # @param hash [Object] a normalized trace (or any JSON-like value)
    # @param segments [Array<String, Integer>]
    # @return [Object] the value at segments, or {ABSENT}
    def lookup(hash, segments)
      segments.reduce(hash) do |node, segment|
        case node
        when Hash
          return ABSENT unless segment.is_a?(String) && node.key?(segment)

          node[segment]
        when Array
          return ABSENT unless segment.is_a?(Integer) && segment >= 0 && segment < node.size

          node[segment]
        else
          return ABSENT
        end
      end
    end

    # A finding reproduces when both controls give the expected value and the candidate
    # doesn't. Values compare strictly by JSON type (1 is not 1.0), as the diff does.
    # @param expected [Object] value or {ABSENT}
    # @param observed [Hash{String=>Object}] role => value or {ABSENT}
    def reproduces?(expected:, observed:)
      same?(observed["control_a"], expected) && same?(observed["control_a_prime"], expected) &&
        !same?(observed["candidate_b"], expected)
    end

    def same?(x, y)
      return x.equal?(y) if x.equal?(ABSENT) || y.equal?(ABSENT)

      return false unless x.instance_of?(y.class)

      case x
      when Hash then x.size == y.size && x.all? { |k, v| y.key?(k) && same?(v, y[k]) }
      when Array then x.size == y.size && x.zip(y).all? { |a, b| same?(a, b) }
      else x == y
      end
    end

    # @return [Hash] {"value" => v} or {"absent" => true}, for repros.json
    def encode_observed(value)
      value.equal?(ABSENT) ? {"absent" => true} : {"value" => value}
    end

    # Replays requests on this process's Rails version and returns normalized traces.
    #
    # @param snapshot [String] SQLite template to restore (a copy is used; the file isn't modified)
    # @param requests [Array<Hash>] protocol requests (method, path, params, headers, offset_ms, as)
    # @param started_at [String] ISO 8601 session start (the frozen clock's origin)
    # @param seed [Integer] the session's rand seed in the original run
    # @param perform_jobs [Boolean] ADR 0014
    # @param http_stubs [Array<Hash>]
    # @param ignored_headers [Array<String>] normalization options of the run
    # @param ignored_columns [Array<String>]
    # @param app_root [String] defaults to the current directory (where `bundle exec` runs)
    # @param gemfile [String] defaults to the current bundle's Gemfile
    # @return [Result]
    def replay(snapshot:, requests:, started_at:, seed:, perform_jobs: true, http_stubs: [],
      ignored_headers: [], ignored_columns: [], app_root: Dir.pwd, gemfile: nil)
      raise Error, "reproduction snapshot not found: #{snapshot}" unless File.exist?(snapshot)

      gemfile = File.expand_path(gemfile || ENV["BUNDLE_GEMFILE"] || File.join(app_root, "Gemfile"), app_root)
      twin = twin_for(File.expand_path(app_root), gemfile)
      session = {"id" => "repro", "started_at" => started_at, "seed" => seed, "snapshot" => File.expand_path(snapshot),
                 "requests" => requests, "http_stubs" => http_stubs}
      raw = twin.run_session(session, {"perform_jobs" => perform_jobs}).fetch("traces")
      normalized = raw.map do |t|
        Normalize::Trace.call(t, session_cookie: twin.hello["session_cookie"], ignored_headers: ignored_headers,
          ignored_columns: ignored_columns)
      end
      Result.new(traces: normalized, rails_version: twin.hello["rails_version"])
    end

    # One booted twin per (app, Gemfile) for the life of the process.
    def twin_for(app_root, gemfile)
      @twins ||= {}
      @twins[[app_root, gemfile]] ||= begin
        install_at_exit
        work = Dir.mktmpdir("doubletrack-repro-")
        @work_dirs << work
        twin = Coordinator::TwinProcess.new(role: "repro", app_root: app_root, gemfile: gemfile, work_dir: work)
        begin
          twin.start
        rescue Doubletrack::Error => e
          tail = e.respond_to?(:log_tail) ? e.log_tail.to_s : ""
          raise Error, "#{e.message}\n--- last lines of the reproduction twin's log ---\n#{tail}"
        end
        twin
      end
    end

    def install_at_exit
      return if @at_exit_installed

      @at_exit_installed = true
      @work_dirs = []
      at_exit { shutdown }
    end

    # Stops every twin this process started. Called at exit.
    def shutdown
      (@twins || {}).each_value { |t| t.stop rescue nil } # rubocop:disable Style/RescueModifier
      (@work_dirs || []).each { |d| FileUtils.rm_rf(d) }
      @twins = {}
      @work_dirs = []
    end
  end
end
