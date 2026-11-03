# frozen_string_literal: true

module Doubletrack
  module Report
    # Plain-language names for finding paths ("performed_jobs[*].mail[*].subject" →
    # "email: subject, in a job performed after the request"), shown next to the
    # technical path, never instead of it.
    module Describe
      CHANNELS = {
        "sql_writes" => "SQL write",
        "jobs" => "enqueued job",
        "mail" => "email",
        "cache" => "cache write",
        "http" => "outbound HTTP call",
        "deprecations" => "deprecation warning"
      }.freeze

      module_function

      # @param path [String] a finding path, e.g. "response.body.json.total"
      # @return [String]
      def thing(path)
        segments = path.to_s.split(".").map { |s| s.delete_suffix("[*]") }
        name(segments) || path.to_s
      end

      # @param op [String] "changed", "added" (only on B) or "removed" (missing on B)
      # @param to [String] the next Rails version
      def sentence(path, op, to:)
        case op
        when "added" then "#{thing(path)} appears only on Rails #{to}"
        when "removed" then "#{thing(path)} is missing on Rails #{to}"
        else "#{thing(path)} changed"
        end
      end

      def name(segments)
        head, *rest = segments
        case head
        when "response" then response(rest)
        when "exception" then rest.empty? ? "exception" : "exception #{rest.join(".")}"
        when "session" then rest.empty? ? "session" : "session value #{rest.join(".")}"
        when "performed_jobs"
          return "performed job" if rest.empty?
          return "performed job: #{rest.join(".")}" unless CHANNELS.key?(rest.first)

          "#{name(rest)}, in a job performed after the request"
        when *CHANNELS.keys
          rest.empty? ? CHANNELS[head] : "#{CHANNELS[head]}: #{rest.join(".")}"
        end
      end

      def response(rest)
        case rest
        in [] then "response"
        in ["status", *] then "HTTP status"
        in ["headers", header, *] then "response header #{header}"
        in ["set_cookies", cookie, *] then "cookie #{cookie}"
        in ["body", "json"] then "JSON response body"
        in ["body", "json", *field] then "JSON response field #{field.join(".")}"
        in ["body", "html", *] then "HTML response body"
        in ["body", *] then "response body"
        else "response #{rest.join(".")}"
        end
      end
    end
  end
end
