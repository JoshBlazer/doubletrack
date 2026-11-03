# frozen_string_literal: true

require "digest"
require "time" # Time#iso8601 is core only from Ruby 3.4

module Doubletrack
  module Recorder
    # Converts arbitrary Ruby values (bind values, cache values, job arguments) into
    # JSON-safe, deterministic structures. Never raises: unknown objects become their
    # `inspect` string. Standard library only; ActiveSupport types are detected by name.
    module Jsonable
      MAX_DEPTH = 20

      module_function

      # @param value [Object]
      # @return [nil, true, false, Integer, Float, String, Array, Hash]
      def call(value, depth = 0)
        return value.inspect if depth > MAX_DEPTH

        case value
        when nil, true, false, Integer then value
        when Float then value.finite? ? value : value.to_s
        when String then string(value)
        when Symbol then value.to_s
        when Array then value.map { |v| call(v, depth + 1) }
        when Hash then value.each_with_object({}) { |(k, v), h| h[key(k)] = call(v, depth + 1) }
        else other(value, depth)
        end
      rescue => e
        "#<unserializable #{value.class}: #{e.class}>"
      end

      # Replaces invalid UTF-8 in every string of a JSON-shaped tree (keys too), so a
      # trace can always be generated. Values that went through .call are already valid;
      # this covers text recorded directly (exception messages, SQL, headers, cache keys).
      def scrub(value)
        case value
        when String then value.valid_encoding? ? value : value.scrub("\uFFFD")
        when Array then value.map { |v| scrub(v) }
        when Hash then value.each_with_object({}) { |(k, v), h| h[scrub(k)] = scrub(v) }
        else value
        end
      end

      # JSON object keys must be text; binary keys become "binary_sha256:<hex>".
      def key(value)
        converted = string(value.to_s)
        converted.is_a?(Hash) ? "binary_sha256:#{converted["binary_sha256"]}" : converted
      end

      def string(value)
        utf8 = value.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding? && !(value.encoding == Encoding::BINARY && !value.ascii_only?)

        {"binary_sha256" => Digest::SHA256.hexdigest(value)}
      end

      def other(value, depth)
        # getutc returns a copy; Time#utc would convert the app's object in place.
        if value.is_a?(Time) || (defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone))
          value.getutc.iso8601(6)
        elsif defined?(DateTime) && value.is_a?(DateTime)
          value.to_time.getutc.iso8601(6)
        elsif defined?(Date) && value.is_a?(Date)
          value.iso8601
        elsif defined?(BigDecimal) && value.is_a?(BigDecimal)
          value.to_s("F")
        elsif defined?(ActiveModel::Type::Binary::Data) && value.is_a?(ActiveModel::Type::Binary::Data)
          {"binary_sha256" => Digest::SHA256.hexdigest(value.to_s)}
        elsif value.respond_to?(:as_json)
          call(value.as_json, depth + 1)
        else
          value.inspect
        end
      end
    end
  end
end
