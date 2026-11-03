# frozen_string_literal: true

require "json"

module Doubletrack
  module Normalize
    # Turns a raw trace (docs/formats/trace.md) into its comparable form: volatile values
    # removed, opaque values replaced by placeholders. Pure: returns a new Hash, never
    # mutates its input, and is idempotent (`call(call(t)) == call(t)`).
    #
    # M2 rules: docs/design/replay.md#normalization-in-m2. Body, SQL and HTML rules
    # arrive with M3 (docs/design/diff.md).
    module Trace
      VOLATILE_HEADERS = %w[x-request-id x-runtime].freeze
      VOLATILE_SESSION_KEYS = %w[session_id _csrf_token].freeze
      EVIDENCE_ONLY = %w[duration_ms deprecations].freeze
      SESSION_PLACEHOLDER = "<session>"
      ADDRESS = /0x\h{6,}/

      module_function

      # @param trace [Hash] raw trace
      # @param session_cookie [String, nil] name of the app's session cookie (from hello)
      # @param ignored_headers [Array<String>] extra response headers to drop
      # @return [Hash] normalized copy
      def call(trace, session_cookie: nil, ignored_headers: [])
        out = deep_copy(trace)
        EVIDENCE_ONLY.each { |key| out.delete(key) }
        out["response"] = response(out["response"], session_cookie, ignored_headers) if out["response"]
        out["session"] = session(out["session"]) if out["session"].is_a?(Hash)
        out["exception"] = exception(out["exception"]) if out["exception"]
        if out["performed_jobs"].is_a?(Array)
          out["performed_jobs"] = out["performed_jobs"].map do |job|
            job["exception"] ? job.merge("exception" => exception(job["exception"])) : job
          end
        end
        out
      end

      def response(response, session_cookie, ignored_headers)
        headers = (response["headers"] || {}).dup
        (VOLATILE_HEADERS + ignored_headers.map(&:downcase)).each { |name| headers.delete(name) }
        cookies = response["set_cookies"] || {}
        if (raw = headers.delete("set-cookie"))
          cookies = cookies.merge(parse_set_cookie(raw))
        end
        if session_cookie && cookies[session_cookie]
          cookies = cookies.merge(session_cookie => cookies[session_cookie].merge("value" => SESSION_PLACEHOLDER))
        end
        out = response.merge("headers" => headers)
        out["set_cookies"] = cookies unless cookies.empty?
        out
      end

      # @param raw [String, Array<String>] one or more Set-Cookie values
      # @return [Hash{String=>Hash}] name => {"value", "attributes" (sorted)}
      def parse_set_cookie(raw)
        Array(raw).flat_map { |v| v.to_s.split("\n") }.each_with_object({}) do |line, cookies|
          pair, *attributes = line.split(";").map(&:strip)
          next if pair.nil? || pair.empty?

          name, value = pair.split("=", 2)
          attributes = attributes.reject(&:empty?).map do |attr|
            key, val = attr.split("=", 2)
            val ? "#{key.downcase}=#{val}" : key.downcase
          end
          cookies[name] = {"value" => value.to_s, "attributes" => attributes.sort}
        end
      end

      def session(hash)
        hash.except(*VOLATILE_SESSION_KEYS)
      end

      def exception(exception)
        {"class" => exception["class"], "message" => exception["message"].to_s.gsub(ADDRESS, "0x…")}
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
