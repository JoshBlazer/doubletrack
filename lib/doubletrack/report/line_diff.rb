# frozen_string_literal: true

module Doubletrack
  module Report
    # Line-level diff for the side-by-side panels on a finding page, so the lines that
    # differ are marked instead of left for the reader to spot. Pure; standard library only.
    module LineDiff
      # Above this many cells (lines × lines, after trimming the common prefix and
      # suffix) the middle is shown as wholly removed and added instead of aligned.
      MAX_CELLS = 2_000_000

      module_function

      # @param a [Array<String>] old lines
      # @param b [Array<String>] new lines
      # @return [Array<Array(Symbol, String)>] [:eq | :del | :ins, line]
      def ops(a, b)
        prefix = 0
        prefix += 1 while prefix < a.size && prefix < b.size && a[prefix] == b[prefix]
        suffix = 0
        suffix += 1 while suffix < a.size - prefix && suffix < b.size - prefix && a[-1 - suffix] == b[-1 - suffix]
        old_mid = a[prefix...(a.size - suffix)]
        new_mid = b[prefix...(b.size - suffix)]
        middle = if old_mid.size * new_mid.size > MAX_CELLS
          old_mid.map { |l| [:del, l] } + new_mid.map { |l| [:ins, l] }
        else
          lcs(old_mid, new_mid)
        end
        a.first(prefix).map { |l| [:eq, l] } + middle + a.last(suffix).map { |l| [:eq, l] }
      end

      # Replaces long runs of unchanged lines, away from any change, with [:skip, count].
      # @param ops [Array] from {ops}
      # @param context [Integer] unchanged lines kept around each change
      # @param min_skip [Integer] shorter runs are shown, not folded
      def fold(ops, context: 3, min_skip: 5)
        return ops if ops.size <= 2 * context + min_skip

        keep = Array.new(ops.size, false)
        ops.each_with_index do |(op, _), i|
          next if op == :eq

          ([i - context, 0].max..[i + context, ops.size - 1].min).each { |k| keep[k] = true }
        end
        out = []
        pending = []
        flush = lambda do
          (pending.size >= min_skip) ? out << [:skip, pending.size] : out.concat(pending)
          pending = []
        end
        ops.each_with_index do |op, i|
          if keep[i]
            flush.call
            out << op
          else
            pending << op
          end
        end
        flush.call
        out
      end

      def lcs(a, b)
        n = a.size
        m = b.size
        table = Array.new(n + 1) { Array.new(m + 1, 0) }
        (n - 1).downto(0) do |i|
          (m - 1).downto(0) do |j|
            table[i][j] = (a[i] == b[j]) ? table[i + 1][j + 1] + 1 : [table[i + 1][j], table[i][j + 1]].max
          end
        end
        out = []
        i = j = 0
        while i < n && j < m
          if a[i] == b[j]
            out << [:eq, a[i]]
            i += 1
            j += 1
          elsif table[i + 1][j] >= table[i][j + 1]
            out << [:del, a[i]]
            i += 1
          else
            out << [:ins, b[j]]
            j += 1
          end
        end
        out.concat(a[i..].map { |l| [:del, l] }).concat(b[j..].map { |l| [:ins, l] })
      end
    end
  end
end
