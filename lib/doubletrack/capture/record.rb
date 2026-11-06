# frozen_string_literal: true

module Doubletrack
  module Capture
    # Turns the arguments of one `ActionDispatch::Integration::Session#process` call into
    # JSON-safe data (docs/design/capture.md). Runs inside the app's test process, so it
    # uses plain Ruby only and never raises: anything it can't represent becomes an
    # "unsupported" reason, and the assembler skips that test.
    module Record
      OPTIONS = %i[params headers env xhr as].freeze
      MAX_UPLOAD_BYTES = 5 * 1024 * 1024 # ADR 0039

      class Unsupported < StandardError; end

      module_function

      # @return [Hash] {"method", "path", "params", "headers", "env", "xhr", "as"[, "unsupported"]}
      def build(method:, path:, **options)
        record = {"method" => method.to_s.downcase, "path" => path.to_s, "params" => nil, "headers" => {}, "env" => {},
                  "xhr" => options[:xhr] ? true : false, "as" => options[:as]&.to_s}
        unknown = options.keys - OPTIONS
        return record.merge("unsupported" => "unknown process option(s): #{unknown.join(", ")}") unless unknown.empty?

        if options[:params].is_a?(String) # a raw request body (ADR 0039)
          body = options[:params].dup.force_encoding(Encoding::UTF_8)
          if body.valid_encoding?
            record["body"] = body
          else
            record["body_base64"] = [options[:params].b].pack("m0")
          end
        else
          record["params"] = jsonable(options[:params], "params")
        end
        record["headers"] = jsonable(options[:headers] || {}, "headers")
        record["env"] = jsonable(options[:env] || {}, "env")
        record
      rescue Unsupported => e
        record.merge("unsupported" => e.message)
      rescue => e
        record.merge("unsupported" => "could not record request: #{e.class}: #{e.message}")
      end

      # An uploaded file (Rack::Test::UploadedFile, as fixture_file_upload makes), read from
      # its path so the test's IO isn't consumed.
      # An upload backed by a StringIO (Rack::Test::UploadedFile.new(StringIO.new(...))) is
      # read through StringIO#string, which doesn't move its position either.
      def upload(file, where)
        io = file.respond_to?(:tempfile) ? file.tempfile : nil
        data = if io.respond_to?(:string)
          io.string.b
        else
          size = File.size(file.path)
          raise Unsupported, "#{where} is an upload of #{size} bytes (at most #{MAX_UPLOAD_BYTES} can be replayed)" if size > MAX_UPLOAD_BYTES

          File.binread(file.path)
        end
        raise Unsupported, "#{where} is an upload of #{data.bytesize} bytes (at most #{MAX_UPLOAD_BYTES} can be replayed)" if data.bytesize > MAX_UPLOAD_BYTES

        {"$upload" => {"filename" => file.original_filename.to_s, "content_type" => file.content_type.to_s,
                       "data_base64" => [data].pack("m0")}}
      end

      def jsonable(value, where)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, jsonable(v, "#{where}.#{k}")] }
        when Array then value.each_with_index.map { |v, i| jsonable(v, "#{where}[#{i}]") }
        when String, Integer, true, false, nil then value
        when Float then value.finite? ? value : raise(Unsupported, "#{where} is a non-finite Float")
        when Symbol then value.to_s
        else
          return upload(value, where) if value.respond_to?(:original_filename) && (value.respond_to?(:tempfile) || value.respond_to?(:path))

          raise Unsupported, "#{where} is a #{value.class} (only JSON-like values and uploaded files can be replayed)"
        end
      end
    end
  end
end
