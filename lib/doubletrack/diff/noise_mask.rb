# frozen_string_literal: true

module Doubletrack
  module Diff
    # Paths that differ between control A and control A′ (ADR 0005, ADR 0019). Keyed by
    # route and concrete path; a recorded path masks itself and everything below it,
    # never its parents.
    class NoiseMask
      # @return [Integer] A/A′ differences seen
      attr_reader :observed

      def initialize
        @paths = Hash.new { |h, k| h[k] = {} }
        @observed = 0
      end

      # @param route_key [String]
      # @param differences [Array<Difference>]
      def add(route_key, differences)
        differences.each do |d|
          @observed += 1
          @paths[route_key][d.path] = true
        end
        self
      end

      # @param path [Array]
      def masked?(route_key, path)
        return false unless @paths.key?(route_key)

        (1..path.size).any? { |n| @paths[route_key].key?(path.first(n)) }
      end

      # @return [Array<String>] masked paths for a route, sorted
      def paths(route_key)
        return [] unless @paths.key?(route_key)

        @paths[route_key].keys.map { |p| Difference.format(p) }.sort
      end

      # @return [Hash{String=>Array<String>}]
      def to_h
        @paths.keys.sort.to_h { |route| [route, paths(route)] }
      end
    end
  end
end
