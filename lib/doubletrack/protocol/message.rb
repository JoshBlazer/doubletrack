# frozen_string_literal: true

module Doubletrack
  module Protocol
    # Incremented on every incompatible change to the envelope or any payload.
    SCHEMA_VERSION = 1

    # Message types, see docs/design/protocol.md#messages.
    TYPES = %w[hello prepare_snapshot run_session result error shutdown].freeze

    # Error codes a twin may send in an `error` payload.
    ERROR_CODES = %w[
      boot_failed bad_message unknown_type schema_mismatch not_implemented session_failed
    ].freeze

    # Builds and validates message envelopes. Messages are plain Hashes with String keys,
    # exactly as they appear after JSON parsing, so there is one representation on both
    # sides of the pipe.
    module Message
      module_function

      # @param id [String] unique per sender
      # @param type [String] one of {TYPES}
      # @param payload [Hash]
      # @param reply_to [String, nil] id of the request being answered
      # @return [Hash] a message envelope
      def build(id:, type:, payload: {}, reply_to: nil)
        message = {
          "schema_version" => SCHEMA_VERSION,
          "id" => id,
          "type" => type,
          "reply_to" => reply_to,
          "payload" => payload
        }
        validate!(message)
      end

      # Builds an `error` message.
      # @return [Hash]
      def error(id:, code:, message:, reply_to: nil, exception: nil)
        payload = {"code" => code, "message" => message}
        if exception
          payload["exception_class"] = exception.class.name
          payload["backtrace"] = Array(exception.backtrace).first(20)
        end
        build(id: id, type: "error", payload: payload, reply_to: reply_to)
      end

      # Checks the envelope. Unknown extra fields are allowed (forward compatibility).
      # @param message [Object] parsed JSON
      # @return [Hash] the message, unchanged
      # @raise [SchemaMismatch, UnknownType, ProtocolError]
      def validate!(message)
        raise ProtocolError, "message must be a JSON object, got #{message.class}" unless message.is_a?(Hash)

        version = message["schema_version"]
        unless version == SCHEMA_VERSION
          raise SchemaMismatch, "schema_version #{version.inspect} is not supported (expected #{SCHEMA_VERSION})"
        end

        id = message["id"]
        raise ProtocolError, "message id must be a non-empty string" unless id.is_a?(String) && !id.empty?

        type = message["type"]
        raise UnknownType, "unknown message type #{type.inspect}" unless TYPES.include?(type)

        reply_to = message["reply_to"]
        raise ProtocolError, "reply_to must be a string or null" unless reply_to.nil? || reply_to.is_a?(String)

        raise ProtocolError, "payload must be a JSON object" unless message["payload"].is_a?(Hash)

        message
      end

      # Encodes a response body (any bytes) for transport.
      # @param bytes [String]
      # @return [Hash] {"encoding" => "utf-8"|"base64", "data" => String}
      def encode_body(bytes)
        text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        if text.valid_encoding?
          {"encoding" => "utf-8", "data" => text}
        else
          {"encoding" => "base64", "data" => [bytes].pack("m0")}
        end
      end

      # Inverse of {encode_body}.
      # @param body [Hash]
      # @return [String] UTF-8 text, or binary (ASCII-8BIT) bytes for base64 bodies
      def decode_body(body)
        case body["encoding"]
        when "utf-8" then body["data"]
        when "base64" then body["data"].unpack1("m0")
        else raise ProtocolError, "unknown body encoding #{body["encoding"].inspect}"
        end
      end
    end
  end
end
