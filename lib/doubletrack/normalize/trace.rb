# frozen_string_literal: true

require "digest"
require "json"
require_relative "json"
require_relative "sql"

module Doubletrack
  module Normalize
    # Turns a raw trace (docs/formats/trace.md) into its comparable form: volatile values
    # removed, opaque values replaced by placeholders, bodies and SQL canonicalized. Pure:
    # returns a new Hash, never mutates its input, and is idempotent
    # (`call(call(t)) == call(t)`).
    #
    # Rules: docs/design/replay.md#normalization-in-m2 and docs/design/diff.md#normalization.
    module Trace
      # Volatile (request id, runtime) or derived from the body, which is compared directly.
      VOLATILE_HEADERS = %w[x-request-id x-runtime etag content-length].freeze
      VOLATILE_SESSION_KEYS = %w[session_id _csrf_token].freeze
      NOT_COMPARED = %w[duration_ms deprecations route time request].freeze
      SESSION_PLACEHOLDER = "<session>"
      ADDRESS = /0x\h{6,}/

      module_function

      # @param trace [Hash] raw trace
      # @param session_cookie [String, nil] name of the app's session cookie (from hello)
      # @param ignored_headers [Array<String>] extra response headers to drop
      # @param ignored_columns [Array<String>] bind columns to drop from SQL writes
      # @return [Hash] normalized copy
      def call(trace, session_cookie: nil, ignored_headers: [], ignored_columns: [])
        out = deep_copy(trace)
        NOT_COMPARED.each { |key| out.delete(key) }
        out["response"] = response(out["response"], session_cookie, ignored_headers) if out["response"]
        out["session"] = session(out["session"]) if out["session"].is_a?(Hash)
        out["exception"] = exception(out["exception"]) if out["exception"]
        channels(out, ignored_columns)
        if out["performed_jobs"].is_a?(Array)
          out["performed_jobs"] = out["performed_jobs"].map do |job|
            job = job.merge("exception" => exception(job["exception"])) if job["exception"]
            channels(job, ignored_columns)
          end
        end
        out
      end

      def channels(target, ignored_columns)
        target["sql_writes"] = target["sql_writes"].map { |w| sql_write(w, ignored_columns) } if target["sql_writes"].is_a?(Array)
        target["mail"] = target["mail"].map { |m| mail(m) } if target["mail"].is_a?(Array)
        target
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
        out["body"] = body(response["body"], headers["content-type"]) if response.key?("body")
        out["set_cookies"] = cookies unless cookies.empty?
        out
      end

      # @param body [Hash] {"encoding", "data"} as recorded, or an already-normalized body
      # @return [Hash] {"json" => tree} | {"html" => tree} | {"text" => String} | {"sha256" => hex}
      def body(body, content_type)
        return body unless body.is_a?(Hash) && body.key?("encoding")

        if body["encoding"] == "base64"
          return {"sha256" => Digest::SHA256.hexdigest(body["data"].to_s.unpack1("m0"))}
        end

        text = body["data"].to_s
        type = content_type.to_s.downcase
        if type.include?("json") && (tree = Json.call(text))
          {"json" => tree}
        elsif type.include?("html") && !text.strip.empty?
          require_relative "html"
          {"html" => Html.call(text)}
        else
          {"text" => text}
        end
      end

      def sql_write(write, ignored_columns)
        return write unless write.is_a?(Hash)

        out = write.except("name")
        if out.key?("sql") && !out.key?("sql_literals")
          canonical = Sql.call(out["sql"])
          out["sql"] = canonical["sql"]
          out["sql_literals"] = canonical["literals"]
        end
        out["binds"] = out["binds"].except(*ignored_columns) if out["binds"].is_a?(Hash)
        out
      end

      def mail(mail)
        return mail unless mail.is_a?(Hash)

        out = mail.dup
        out["text_body"] = out["text_body"].gsub(/[ \t]+$/, "") if out["text_body"].is_a?(String)
        if out["html_body"].is_a?(String)
          require_relative "html"
          out["html_body"] = Html.canonical(out["html_body"])
        end
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
