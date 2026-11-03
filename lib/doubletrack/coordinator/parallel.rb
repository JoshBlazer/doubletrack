# frozen_string_literal: true

require_relative "../errors"

module Doubletrack
  module Coordinator
    module_function

    # Runs the block for each item in its own thread and returns the results in order.
    # Every thread is joined before the first error is re-raised: a twin whose thread
    # failed must not leave the others mid-request, or the next request (or `stop`) on
    # them would race with a reply still in flight.
    #
    # @return [Array]
    def parallel_map(items, &block)
      threads = items.map do |item|
        Thread.new do
          Thread.current.report_on_exception = false # we re-raise; no duplicate backtraces
          block.call(item)
        end
      end
      errors = []
      results = threads.map do |t|
        t.value
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised below after every join
        errors << e
        nil
      end
      raise errors.first unless errors.empty?

      results
    end
  end
end
