# frozen_string_literal: true

module Doubletrack
  module Protocol
    # Hard upper bound for one NDJSON frame, in bytes.
    MAX_FRAME_BYTES = 64 * 1024 * 1024

    # Writes one message per line. Not thread-safe; each pipe has a single writer.
    class Writer
      # @param io [IO] write end of a pipe
      def initialize(io)
        @io = io
        @io.sync = true
      end

      # @param message [Hash] a valid envelope (validated again here)
      # @return [void]
      # @raise [Errno::EPIPE] when the peer has gone away
      def write(message)
        Message.validate!(message)
        @io.write(JSON.generate(message), "\n")
        nil
      end

      def close
        @io.close unless @io.closed?
      end
    end

    # Reads NDJSON frames with an optional deadline, never blocking past it.
    class Reader
      CHUNK_BYTES = 64 * 1024

      # @param io [IO] read end of a pipe
      # @param max_frame_bytes [Integer]
      def initialize(io, max_frame_bytes: MAX_FRAME_BYTES)
        @io = io
        @max_frame_bytes = max_frame_bytes
        @buffer = String.new(encoding: Encoding::BINARY)
      end

      # Reads the next message.
      # @param timeout [Numeric, nil] seconds; nil waits forever
      # @return [Hash] a validated envelope
      # @raise [ReadTimeout] no complete message before the deadline
      # @raise [Closed] EOF before a complete message
      # @raise [ProtocolError] invalid JSON / envelope, or frame too large
      def read(timeout: nil)
        deadline = timeout && (monotonic_now + timeout)
        loop do
          line = take_line
          return decode(line) if line

          if @buffer.bytesize > @max_frame_bytes
            raise FrameTooLarge, "frame exceeds #{@max_frame_bytes} bytes"
          end

          fill(deadline)
        end
      end

      def close
        @io.close unless @io.closed?
      end

      private

      def take_line
        newline = @buffer.index("\n")
        return nil unless newline

        if newline > @max_frame_bytes
          raise FrameTooLarge, "frame exceeds #{@max_frame_bytes} bytes"
        end

        line = @buffer.byteslice(0, newline)
        @buffer = @buffer.byteslice(newline + 1, @buffer.bytesize - newline - 1)
        line
      end

      def fill(deadline)
        remaining = deadline && (deadline - monotonic_now)
        raise ReadTimeout, "no message within the deadline" if remaining && remaining <= 0

        ready = IO.select([@io], nil, nil, remaining)
        raise ReadTimeout, "no message within the deadline" unless ready

        chunk = @io.read_nonblock(CHUNK_BYTES, exception: false)
        case chunk
        when :wait_readable
          nil
        when nil
          raise Closed, "peer closed the pipe" if @buffer.empty?

          raise Closed, "peer closed the pipe mid-frame (#{@buffer.bytesize} bytes buffered)"
        else
          @buffer << chunk
        end
      end

      def decode(line)
        text = line.force_encoding(Encoding::UTF_8)
        raise ProtocolError, "frame is not valid UTF-8" unless text.valid_encoding?

        Message.validate!(JSON.parse(text))
      rescue JSON::ParserError => e
        raise ProtocolError, "frame is not valid JSON: #{e.message[0, 200]}"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
