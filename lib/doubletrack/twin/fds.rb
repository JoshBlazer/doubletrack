# frozen_string_literal: true

module Doubletrack
  module Twin
    # The twin's protocol pipes (docs/design/protocol.md). Standard library only: this
    # runs before the app's bundle is set up.
    module Fds
      module_function

      # @param env [Hash] DOUBLETRACK_FD_IN / DOUBLETRACK_FD_OUT
      # @return [Array(IO, IO)] input, output
      def open(env = ENV)
        input = IO.for_fd(Integer(env.fetch("DOUBLETRACK_FD_IN")), "rb", autoclose: true)
        output = IO.for_fd(Integer(env.fetch("DOUBLETRACK_FD_OUT")), "wb", autoclose: true)
        # Subprocesses the app starts must not inherit the pipes: one that outlives the
        # twin would hold fd 4 open, and the coordinator would wait for a reply until its
        # timeout instead of seeing the crash (EOF) at once.
        [input, output].each { |io| io.close_on_exec = true }
        output.sync = true
        [input, output]
      end
    end
  end
end
