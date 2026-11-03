# frozen_string_literal: true

# Error hierarchy. Standard library only: this file is loaded inside twins before (and
# independently of) the target app's bundle.
module Doubletrack
  # Base class for every error Doubletrack raises on purpose. The CLI maps these to exit 2.
  class Error < StandardError; end

  module Protocol
    # The peer sent something that is not a valid protocol message.
    class ProtocolError < Doubletrack::Error; end

    # The peer speaks a different schema_version.
    class SchemaMismatch < ProtocolError; end

    # The message type is not one this side understands.
    class UnknownType < ProtocolError; end

    # A frame exceeded {Protocol::MAX_FRAME_BYTES}.
    class FrameTooLarge < ProtocolError; end

    # No complete message arrived before the deadline.
    class ReadTimeout < Doubletrack::Error; end

    # The peer closed its end of the pipe (EOF).
    class Closed < Doubletrack::Error; end
  end

  # A twin failed. Carries the twin's role and the tail of its log for diagnosis.
  class TwinError < Error
    attr_reader :role, :code, :log_tail

    def initialize(message, role: nil, code: nil, log_tail: nil)
      @role = role
      @code = code
      @log_tail = log_tail
      super(message)
    end

    def full_message(highlight: false, order: :top)
      return super if log_tail.nil? || log_tail.empty?

      "#{super}\n--- last lines of twin log (#{role}) ---\n#{log_tail}"
    end
  end

  # The twin reported boot_failed instead of hello.
  class TwinBootFailed < TwinError; end

  # The twin process exited or closed its protocol pipe unexpectedly.
  class TwinCrashed < TwinError; end

  # The twin did not answer before the deadline and was killed.
  class TwinTimeout < TwinError; end

  # The twin answered a request with an error message.
  class TwinRequestFailed < TwinError; end
end
