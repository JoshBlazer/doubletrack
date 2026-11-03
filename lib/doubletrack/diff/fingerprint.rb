# frozen_string_literal: true

require "digest"
require "json"

module Doubletrack
  module Diff
    # Finding identity (ADR 0019): channel + route + generalized path + op + value shape.
    # At enumerated leaves the values themselves are the shape.
    module Fingerprint
      ENUMERATED_LEAVES = %w[status class statement table job_class queue_name mailer method op content-type].freeze
      CHANNELS = %w[sql_writes jobs mail cache http].freeze
      # Differences inside an HTML body tree are one location: index paths in a document
      # tree mean nothing to a reader, and one changed element shifts every later index.
      HTML_BODY = ["response", "body", "html"].freeze

      module_function

      # @param route_key [String]
      # @param difference [Difference]
      # @return [String] "f-" + 12 hex characters
      def call(route_key:, difference:)
        path, op = location(difference)
        material = [kind(difference.path), route_key, path, op, html_body?(difference) ? [] : shape(difference)]
        "f-#{Digest::SHA256.hexdigest(JSON.generate(material))[0, 12]}"
      end

      # @return [Array(String, String)] the generalized path and op a finding is filed under
      def location(difference)
        html_body?(difference) ? ["response.body.html", "changed"] : [difference.generalized, difference.op]
      end

      def html_body?(difference)
        difference.path.size > HTML_BODY.size && difference.path.first(HTML_BODY.size) == HTML_BODY
      end

      # @return [String] the channel, e.g. "sql_writes" or "performed_jobs.mail"
      def kind(path)
        head = path.first.to_s
        if head == "performed_jobs" && CHANNELS.include?(path[2])
          "performed_jobs.#{path[2]}"
        else
          head
        end
      end

      def shape(difference)
        if ENUMERATED_LEAVES.include?(difference.path.last.to_s)
          [difference.a, difference.b]
        else
          [type(difference.a), type(difference.b)]
        end
      end

      def type(value)
        case value
        when nil then "null"
        when true, false then "boolean"
        when Integer then "integer"
        when Float then "float"
        when String then "string"
        when Array then "array"
        when Hash then "object"
        else value.class.name
        end
      end
    end
  end
end
