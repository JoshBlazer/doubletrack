# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "errors"

module Doubletrack
  # One replay session, loaded from `sessions/*.jsonl` (docs/formats/session.md).
  # Coordinator side: validates strictly and fills defaults, so twins receive
  # complete, explicit requests.
  class Session
    VERSION = 1
    DEFAULT_STARTED_AT = "2026-01-01T00:00:00Z"
    DEFAULT_STEP_MS = 1000
    ID_PATTERN = /\A[A-Za-z0-9._-]{1,100}\z/
    METHODS = %w[GET POST PUT PATCH DELETE HEAD].freeze
    SESSION_KEYS = %w[session_version id started_at snapshot requests http_stubs].freeze
    REQUEST_KEYS = %w[method path params headers as offset_ms].freeze
    STUB_KEYS = %w[method url match status headers body].freeze

    attr_reader :id, :started_at, :requests, :http_stubs, :source

    # Loads every `*.jsonl` file in `dir`, sorted by name.
    # @param dir [String]
    # @return [Array<Session>]
    # @raise [SessionError]
    def self.load_dir(dir)
      raise SessionError, "sessions directory not found: #{dir}" unless File.directory?(dir)

      seen = {}
      sessions = Dir.glob(File.join(dir, "*.jsonl")).sort.flat_map do |path|
        File.foreach(path).with_index(1).filter_map do |text, lineno|
          next if text.strip.empty? || text.lstrip.start_with?("#")

          source = "#{File.basename(path)}:#{lineno}"
          session = parse(text, source: source)
          raise SessionError, "#{source}: duplicate session id #{session.id.inspect} (first at #{seen[session.id]})" if seen[session.id]

          seen[session.id] = source
          session
        end
      end
      raise SessionError, "no sessions found in #{dir} (expected *.jsonl files)" if sessions.empty?

      sessions
    end

    # @param text [String] one JSON line
    # @param source [String] "file:line", used in error messages
    # @return [Session]
    def self.parse(text, source: "session")
      data = JSON.parse(text)
      new(data, source: source)
    rescue JSON::ParserError => e
      raise SessionError, "#{source}: invalid JSON: #{e.message.lines.first&.strip}"
    end

    # Per-session RNG seed, independent of the session's position in the run.
    # @return [Integer] 0...2**64
    def self.seed_for(run_seed, session_id)
      Digest::SHA256.hexdigest("#{run_seed}:#{session_id}")[0, 16].to_i(16)
    end

    def initialize(data, source:)
      @source = source
      fail!("session must be a JSON object") unless data.is_a?(Hash)
      unknown!(data, SESSION_KEYS)
      fail!("session_version must be #{VERSION} (got #{data["session_version"].inspect})") unless data["session_version"] == VERSION

      @id = data["id"]
      fail!("id must match #{ID_PATTERN.source}") unless @id.is_a?(String) && ID_PATTERN.match?(@id)
      @started_at = parse_time(data.fetch("started_at", DEFAULT_STARTED_AT))
      snapshot = data.fetch("snapshot", "default")
      fail!("snapshot must be \"default\" (the only snapshot in the MVP)") unless snapshot == "default"

      raw = data["requests"]
      fail!("requests must be an array with at least one request") unless raw.is_a?(Array) && !raw.empty?
      @requests = raw.each_with_index.map { |r, i| request(r, i) }
      offsets = @requests.map { |r| r["offset_ms"] }
      fail!("offset_ms must be non-decreasing") unless offsets.each_cons(2).all? { |a, b| a <= b }

      @http_stubs = Array(data["http_stubs"]).map { |s| stub(s) }
      freeze
    end

    # The `session` object of a run_session message (docs/design/protocol.md).
    # @return [Hash]
    def to_payload(run_seed:, snapshot:)
      {
        "id" => id,
        "started_at" => started_at,
        "seed" => self.class.seed_for(run_seed, id),
        "snapshot" => snapshot,
        "requests" => requests,
        "http_stubs" => http_stubs
      }
    end

    private

    def request(raw, index)
      fail!("requests[#{index}] must be an object") unless raw.is_a?(Hash)
      unknown!(raw, REQUEST_KEYS, "requests[#{index}]")
      method = raw.fetch("method", "GET").to_s.upcase
      fail!("requests[#{index}].method must be one of #{METHODS.join(", ")}") unless METHODS.include?(method)
      path = raw["path"]
      fail!("requests[#{index}].path must be a string starting with /") unless path.is_a?(String) && path.start_with?("/")
      %w[params headers].each do |key|
        fail!("requests[#{index}].#{key} must be an object") unless raw.fetch(key, {}).is_a?(Hash)
      end
      offset = raw.fetch("offset_ms", DEFAULT_STEP_MS * index)
      fail!("requests[#{index}].offset_ms must be an integer >= 0") unless offset.is_a?(Integer) && offset >= 0

      out = {"method" => method, "path" => path, "params" => raw.fetch("params", {}),
             "headers" => raw.fetch("headers", {}), "offset_ms" => offset}
      out["as"] = raw["as"].to_s if raw["as"]
      out
    end

    def stub(raw)
      fail!("http_stubs entries must be objects") unless raw.is_a?(Hash)
      unknown!(raw, STUB_KEYS, "http_stubs[]")
      fail!("http_stubs[].url must be a string") unless raw["url"].is_a?(String)
      fail!("http_stubs[].match must be exact or prefix") unless [nil, "exact", "prefix"].include?(raw["match"])
      raw
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
      value.to_s
    rescue ArgumentError
      fail!("started_at must be an ISO 8601 time (got #{value.inspect})")
    end

    def unknown!(hash, allowed, where = nil)
      extra = hash.keys - allowed
      return if extra.empty?

      prefix = where ? "#{where}: " : ""
      fail!("#{prefix}unknown key #{extra.first.inspect} (allowed: #{allowed.join(", ")})")
    end

    def fail!(message)
      raise SessionError, "#{@source}: #{message}"
    end
  end
end
