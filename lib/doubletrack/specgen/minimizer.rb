# frozen_string_literal: true

module Doubletrack
  module Specgen
    # Verifies a truncated session reproduces a finding, then greedily drops earlier
    # requests that aren't needed (ADR 0023). The last request (the finding's) is always
    # kept.
    class Minimizer
      MAX_STEPS = 20

      Outcome = Data.define(:status, :requests, :kept, :observed)

      # @param replay [#call] (requests) -> {role => value or Repro::ABSENT} for the last request
      # @param max_steps [Integer] removal attempts at most
      def initialize(replay:, max_steps: MAX_STEPS)
        @replay = replay
        @max_steps = max_steps
      end

      # @param requests [Array<Hash>] the session truncated after the finding's request
      # @param expected [Object] control A's value, or Repro::ABSENT
      # @return [Outcome]
      def call(requests:, expected:)
        kept = (0...requests.size).to_a
        observed = @replay.call(requests)
        unless Repro.reproduces?(expected: expected, observed: observed)
          return Outcome.new(status: "not_reproduced", requests: requests, kept: kept, observed: observed)
        end

        candidates = kept[0...-1].reverse.first(@max_steps)
        candidates.each do |index|
          trial = kept - [index]
          result = @replay.call(trial.map { |i| requests[i] })
          next unless Repro.reproduces?(expected: expected, observed: result)

          kept = trial
          observed = result
        end
        Outcome.new(status: "reproduced", requests: kept.map { |i| requests[i] }, kept: kept, observed: observed)
      end
    end
  end
end
