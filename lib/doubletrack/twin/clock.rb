# frozen_string_literal: true

require "date"
require "time"

module Doubletrack
  module Twin
    # A process-wide frozen clock for replay (ADR 0015). Standard library only, so the
    # same code runs in every twin regardless of the app's ActiveSupport version.
    #
    # @example
    #   Clock.install!
    #   Clock.freeze_at("2026-01-15T09:30:00Z") { Time.now } # => 2026-01-15 09:30:00 UTC
    module Clock
      @frozen = nil

      # Prepended to Time's singleton class.
      module TimeMethods
        def now(*args, **kwargs)
          frozen = Clock.frozen
          return super unless frozen

          kwargs.key?(:in) ? at(frozen, in: kwargs[:in]) : at(frozen)
        end

        # Only the argument-less form means "now"; Time.new(y, m, d, ...) is untouched.
        def new(*args, **kwargs)
          return super unless args.empty? && Clock.frozen && (kwargs.keys - [:in]).empty?

          now(**kwargs)
        end
      end

      # Prepended to Date's singleton class.
      module DateMethods
        def today(*args)
          Clock.frozen ? Time.now.to_date : super
        end
      end

      # Prepended to DateTime's singleton class.
      module DateTimeMethods
        def now(*args)
          Clock.frozen ? Time.now.to_datetime : super
        end
      end

      class << self
        # @return [Rational, nil] the frozen instant (seconds since the epoch), if any
        attr_reader :frozen

        # Idempotent.
        def install!
          Time.singleton_class.prepend(TimeMethods) unless Time.singleton_class.include?(TimeMethods)
          Date.singleton_class.prepend(DateMethods) unless Date.singleton_class.include?(DateMethods)
          DateTime.singleton_class.prepend(DateTimeMethods) unless DateTime.singleton_class.include?(DateTimeMethods)
        end

        # Runs the block with the clock frozen at `time`; restores the previous state after.
        # @param time [Time, String] a Time or an ISO 8601 string
        def freeze_at(time)
          previous = @frozen
          @frozen = coerce(time)
          yield
        ensure
          @frozen = previous
        end

        private

        def coerce(time)
          instant = time.is_a?(String) ? Time.iso8601(time) : time
          raise ArgumentError, "expected a Time or ISO 8601 string, got #{time.inspect}" unless instant.respond_to?(:to_r)

          # Store an exact Rational so Time.at reproduces it with full precision.
          instant.to_r
        end
      end
    end
  end
end
