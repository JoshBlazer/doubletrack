# frozen_string_literal: true

module Doubletrack
  module Capture
    # Turns the arguments of one `ActionDispatch::Integration::Session#process` call into
    # JSON-safe data (docs/design/capture.md). Runs inside the app's test process, so it
    # uses plain Ruby only and never raises: anything it can't represent becomes an
    # "unsupported" reason, and the assembler skips that test.
    module Record
      OPTIONS = %i[params headers env xhr as].freeze

      class Unsupported < StandardError; end

      module_function

      # @return [Hash] {"method", "path", "params", "headers", "env", "xhr", "as"[, "unsupported"]}
      def build(method:, path:, **options)
        record = {"method" => method.to_s.downcase, "path" => path.to_s, "params" => nil, "headers" => {}, "env" => {},
                  "xhr" => options[:xhr] ? true : false, "as" => options[:as]&.to_s}
        unknown = options.keys - OPTIONS
        return record.merge("unsupported" => "unknown process option(s): #{unknown.join(", ")}") unless unknown.empty?

        record["params"] = jsonable(options[:params], "params")
        record["headers"] = jsonable(options[:headers] || {}, "headers")
        record["env"] = jsonable(options[:env] || {}, "env")
        record
      rescue Unsupported => e
        record.merge("unsupported" => e.message)
      rescue => e
        record.merge("unsupported" => "could not record request: #{e.class}: #{e.message}")
      end

      def jsonable(value, where)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, jsonable(v, "#{where}.#{k}")] }
        when Array then value.each_with_index.map { |v, i| jsonable(v, "#{where}[#{i}]") }
        when String, Integer, true, false, nil then value
        when Float then value.finite? ? value : raise(Unsupported, "#{where} is a non-finite Float")
        when Symbol then value.to_s
        else raise Unsupported, "#{where} is a #{value.class} (only JSON-like values can be replayed)"
        end
      end
    end
  end
end
