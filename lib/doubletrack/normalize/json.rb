# frozen_string_literal: true

require "json"

module Doubletrack
  module Normalize
    # JSON bodies: parsed, keys sorted recursively. Numbers are kept as parsed, so
    # `1.50` and `1.5` compare equal but `1` and `1.0` do not (clients see the type).
    module Json
      module_function

      # @param text [String]
      # @return [Object, nil] canonical tree, or nil if `text` is not JSON
      def call(text)
        canonical(JSON.parse(text))
      rescue JSON::ParserError, EncodingError
        nil
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |k| [k, canonical(value[k])] }
        when Array then value.map { |v| canonical(v) }
        else value
        end
      end
    end
  end
end
