# frozen_string_literal: true

module Doubletrack
  module Diff
    # One leaf-level difference between two normalized traces.
    # `path` is an Array of String (hash keys) and Integer (array indices).
    Difference = Data.define(:path, :op, :a, :b) do
      # @return [String] e.g. "sql_writes[0].binds.total_cents"
      def path_string
        Difference.format(path)
      end

      # @return [String] indices replaced by [*], e.g. "sql_writes[*].binds.total_cents"
      def generalized
        Difference.format(path.map { |seg| seg.is_a?(Integer) ? :* : seg })
      end

      def self.format(path)
        path.each_with_object(+"") do |seg, out|
          out << case seg
          when Integer then "[#{seg}]"
          when :* then "[*]"
          else out.empty? ? seg.to_s : ".#{seg}"
          end
        end
      end
    end
  end
end
