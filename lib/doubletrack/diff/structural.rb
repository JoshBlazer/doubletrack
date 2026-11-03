# frozen_string_literal: true

module Doubletrack
  module Diff
    # Leaf-level structural diff of two JSON-like values (docs/design/diff.md#structural-diff).
    # Hashes by key, arrays by index (no alignment), a type change is one `changed` at that
    # node. `1` and `1.0` differ.
    module Structural
      module_function

      # @return [Array<Difference>]
      def call(a, b, path = [], out = [])
        if a.is_a?(Hash) && b.is_a?(Hash)
          (a.keys | b.keys).each do |key|
            if !b.key?(key) then out << Difference.new(path: path + [key], op: "removed", a: a[key], b: nil)
            elsif !a.key?(key) then out << Difference.new(path: path + [key], op: "added", a: nil, b: b[key])
            else call(a[key], b[key], path + [key], out)
            end
          end
        elsif a.is_a?(Array) && b.is_a?(Array)
          [a.size, b.size].max.times do |i|
            if i >= b.size then out << Difference.new(path: path + [i], op: "removed", a: a[i], b: nil)
            elsif i >= a.size then out << Difference.new(path: path + [i], op: "added", a: nil, b: b[i])
            else call(a[i], b[i], path + [i], out)
            end
          end
        elsif !same?(a, b)
          out << Difference.new(path: path, op: "changed", a: a, b: b)
        end
        out
      end

      def same?(a, b)
        a.instance_of?(b.class) && a == b
      end

      # Applies differences to a deep copy of `a` (used to property-test {call}).
      def apply(a, differences)
        result = Marshal.load(Marshal.dump(a))
        removals = differences.select { |d| d.op == "removed" }
        (differences - removals).each { |d| set(result, d.path, d.b) }
        # Remove deepest/last indices first so earlier indices stay valid.
        removals.sort_by { |d| [-d.path.size, -(d.path.last.is_a?(Integer) ? d.path.last : 0)] }.each do |d|
          parent = d.path[0...-1].reduce(result) { |node, seg| node[seg] }
          parent.is_a?(Array) ? parent.delete_at(d.path.last) : parent.delete(d.path.last)
        end
        result
      end

      def set(root, path, value)
        return value if path.empty?

        parent = path[0...-1].reduce(root) { |node, seg| node[seg] }
        parent[path.last] = value
        root
      end
    end
  end
end
