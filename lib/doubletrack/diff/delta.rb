# frozen_string_literal: true

module Doubletrack
  module Diff
    # How a value changed, independent of where (docs/design/changes.md, ADR 0031): the
    # tokens a string gained and lost, or the value shapes otherwise. Findings with the
    # same delta at the same path are one change.
    module Delta
      SEPARATORS = /[\s,;=()"'<>]+/

      module_function

      # @param path [Array<String, Integer>] the difference path (for enumerated leaves)
      # @return [Hash] {"added" => [...], "removed" => [...]} or {"from" => ..., "to" => ...}
      def call(path, a, b)
        if text?(a) && text?(b) && !(a.nil? && b.nil?)
          ta = tokens(a)
          tb = tokens(b)
          added = minus(tb, ta)
          removed = minus(ta, tb)
          return {"added" => added.uniq.sort, "removed" => removed.uniq.sort} unless added.empty? && removed.empty?
        end
        {"from" => shape(path, a), "to" => shape(path, b)}
      end

      # Runs of two or more consecutive words in b that aren't in the longest common
      # subsequence with a: phrases to search for ("end of input").
      # @return [Array<String>]
      def added_runs(a, b)
        ta = tokens(a)
        tb = tokens(b)
        kept = lcs_flags(ta, tb)
        runs = []
        current = []
        tb.each_with_index do |token, i|
          if kept[i]
            runs << current.join(" ") if current.size >= 2
            current = []
          else
            current << token
          end
        end
        runs << current.join(" ") if current.size >= 2
        runs
      end

      def tokens(value)
        value.to_s.split(SEPARATORS).reject(&:empty?)
      end

      def text?(value) = value.nil? || value.is_a?(String)

      # Multiset difference.
      def minus(left, right)
        counts = right.tally
        left.reject do |t|
          if counts[t].to_i.positive?
            counts[t] -= 1
            true
          end
        end
      end

      def shape(path, value)
        if Fingerprint::ENUMERATED_LEAVES.include?(path.last.to_s)
          value
        else
          Fingerprint.type(value)
        end
      end

      # @return [Array<Boolean>] for each token of b, whether it is in an LCS with a
      def lcs_flags(a, b)
        table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
        a.size.downto(1) do |i|
          b.size.downto(1) do |j|
            table[i - 1][j - 1] = (a[i - 1] == b[j - 1]) ? table[i][j] + 1 : [table[i][j - 1], table[i - 1][j]].max
          end
        end
        flags = Array.new(b.size, false)
        i = j = 0
        while i < a.size && j < b.size
          if a[i] == b[j]
            flags[j] = true
            i += 1
            j += 1
          elsif table[i + 1][j] >= table[i][j + 1]
            i += 1
          else
            j += 1
          end
        end
        flags
      end
    end
  end
end
