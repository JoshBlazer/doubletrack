# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require_relative "../session"

module Doubletrack
  module Capture
    # Captured records → replay sessions (docs/design/capture.md). Pure: no I/O.
    class Assembler
      DEFAULT_HOST = "www.example.com" # ActionDispatch::Integration::Session::DEFAULT_HOST
      Result = Data.define(:sessions, :stats)

      SECRET_NAME = /KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH/i
      MIN_SECRET_LENGTH = 8
      XHR_ACCEPT = "text/javascript, text/html, application/xml, text/xml, */*"
      HEADER_ENV = /\A(HTTP_\w+|CONTENT_TYPE|CONTENT_LENGTH)\z/
      MAX_ID = 100

      # @param env [Hash{String=>String}]
      # @return [Hash{String=>String}] secret-looking variables worth redacting
      def self.secrets_from(env)
        env.select { |name, value| SECRET_NAME.match?(name) && value.is_a?(String) && value.size >= MIN_SECRET_LENGTH }
      end

      # @param result [Result]
      # @param header [Array<String>] comment lines for the top of the file
      # @return [String] a sessions file (docs/formats/session.md)
      def self.to_jsonl(result, header: [])
        lines = header.map { |l| "# #{l}" }
        result.sessions.each do |s|
          lines << "# #{s["comment"]}"
          lines << JSON.generate(s["session"])
        end
        lines.join("\n") + "\n"
      end

      # @param http_stubs [Array<Hash>] added to every session
      # @param secrets [Hash{String=>String}] name => value to redact
      def initialize(http_stubs: [], secrets: {})
        @http_stubs = http_stubs
        @secrets = secrets.sort_by { |_, v| -v.size }
      end

      # @param records [Array<Hash>] probe output
      # @return [Result]
      def call(records)
        @redactions = 0
        skipped = []
        # Grouped by test id when the probe has one (RSpec example ids): two examples can
        # share a description, and merging them would replay one on the other's state.
        by_test = records.group_by { |r| [r["test"].to_s, r["test_id"].to_s] }
        built = by_test.keys.sort.filter_map do |key|
          test = key.first
          group = by_test[key].sort_by { |r| [r["pid"].to_i, r["seq"].to_i] }
          requests = group.map { |r| request(r) }
          {"test" => test, "location" => group.first["location"], "requests" => requests}
        rescue Skip => e
          skipped << {"test" => test, "reason" => e.message}
          nil
        end

        seen = {}
        used_ids = {}
        sessions = []
        duplicates = 0
        built.each do |b|
          key = JSON.generate(b["requests"])
          if (original = seen[key])
            original["also"] << b["test"]
            duplicates += 1
            next
          end
          entry = {"test" => b["test"], "location" => b["location"], "also" => [], "requests" => b["requests"]}
          seen[key] = entry
          sessions << entry
        end

        out = sessions.map do |e|
          id = unique_id(e["test"], used_ids)
          comment = e["test"].dup
          comment << " (#{e["location"]})" if e["location"]
          comment << "; also #{e["also"].join(", ")}" unless e["also"].empty?
          session = {"session_version" => Session::VERSION, "id" => id, "snapshot" => "fixtures", "requests" => e["requests"]}
          session["http_stubs"] = @http_stubs unless @http_stubs.empty?
          {"comment" => comment.gsub(/[\r\n]+/, " "), "session" => session}
        end

        stats = {
          "tests" => built.size + skipped.size,
          "sessions" => out.size,
          "requests" => out.sum { |s| s["session"]["requests"].size },
          "duplicates" => duplicates,
          "skipped" => skipped,
          "redactions" => @redactions
        }
        Result.new(sessions: out, stats: stats)
      end

      private

      class Skip < StandardError; end

      def request(record)
        raise Skip, record["unsupported"] if record["unsupported"]

        method = record["method"].to_s.upcase
        raise Skip, "#{method} requests can't be replayed (supported: #{Session::METHODS.join(", ")})" unless Session::METHODS.include?(method)

        params = record["params"]
        raise Skip, "params must be a Hash (got #{params.class})" unless params.nil? || params.is_a?(Hash)

        headers = (record["headers"] || {}).transform_values(&:to_s)
        (record["env"] || {}).each do |key, value|
          raise Skip, "env key #{key.inspect} can't be replayed (only HTTP_* headers)" unless HEADER_ENV.match?(key)

          headers[header_name(key)] = value.to_s
        end
        if record["xhr"]
          headers["X-Requested-With"] = "XMLHttpRequest"
          headers["Accept"] ||= XHR_ACCEPT
        end

        path, url_host, url_https = path_of(record["path"].to_s)
        out = {"method" => method, "path" => redact(path)}
        out["params"] = redact(params) if params && !params.empty?
        out["body"] = redact(record["body"]) if record["body"]
        out["body_base64"] = record["body_base64"] if record["body_base64"]
        host = url_host || record["host"]
        out["host"] = host if host && host != DEFAULT_HOST
        out["https"] = true if url_host ? url_https : record["https"] == true
        out["headers"] = redact(headers) unless headers.empty?
        out["as"] = record["as"] if record["as"]
        status = record["raised"] ? "raised" : record["status"]
        out["test_status"] = status if status
        out
      end

      # @return [Array(String, String, Boolean)] [path with query, host from a full URL or nil, https]
      def path_of(path)
        return [path, nil, false] if path.start_with?("/")

        uri = URI.parse(path)
        raise Skip, "path #{path.inspect} is not a URL or absolute path" unless uri.path

        [[uri.path.empty? ? "/" : uri.path, uri.query].compact.join("?"), uri.host, uri.scheme == "https"]
      rescue URI::InvalidURIError
        raise Skip, "path #{path.inspect} is not a valid URL"
      end

      def header_name(key)
        key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
      end

      def redact(value)
        case value
        when Hash then value.to_h { |k, v| [redact(k), redact(v)] }
        when Array then value.map { |v| redact(v) }
        when String
          @secrets.reduce(value) do |text, (name, secret)|
            next text unless text.include?(secret)

            @redactions += text.scan(secret).size
            text.gsub(secret, "[REDACTED:#{name}]")
          end
        else value
        end
      end

      def unique_id(test, used)
        base = test.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-")
        base = "session" if base.empty?
        id = base
        if id.size > MAX_ID || used[id]
          id = "#{base[0, MAX_ID - 9]}-#{Digest::SHA256.hexdigest(test)[0, 8]}"
        end
        id = "#{id[0, MAX_ID - 3]}-#{used.size}" while used[id]
        used[id] = true
        id
      end
    end
  end
end
