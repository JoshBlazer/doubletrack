# frozen_string_literal: true

module Doubletrack
  module Normalize
    # Canonical SQL text plus the inline literals it contained (ADR 0018). Boring on
    # purpose: a small tokenizer, not a parser. Identifier quotes are dropped, placeholders
    # unified to `?`, and literals (strings, numbers, NULL, TRUE/FALSE) replaced by `?`
    # and returned in order.
    module Sql
      TOKEN = /
        (?<string>'(?:[^']|'')*')
        | (?<quoted>"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\])
        | (?<placeholder>\?|\$\d+)
        | (?<word>[A-Za-z_][A-Za-z0-9_$.]*)
        | (?<number>-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)
        | (?<space>\s+)
        | (?<other>.)
      /mx
      KEYWORD_LITERALS = {"NULL" => nil, "TRUE" => true, "FALSE" => false}.freeze

      module_function

      # @param sql [String]
      # @return [Hash] {"sql" => String, "literals" => Array}
      def call(sql)
        out = +""
        literals = []
        previous = nil
        sql.to_s.scan(TOKEN) do
          m = Regexp.last_match
          piece =
            if m[:string]
              literals << m[:string][1..-2].gsub("''", "'")
              "?"
            elsif m[:quoted]
              m[:quoted][1..-2]
            elsif m[:placeholder]
              "?"
            elsif m[:word]
              if KEYWORD_LITERALS.key?(m[:word].upcase)
                literals << KEYWORD_LITERALS[m[:word].upcase]
                "?"
              else
                m[:word]
              end
            elsif m[:number]
              # A leading "-" right after a value is subtraction, not a sign.
              if m[:number].start_with?("-") && previous && previous.match?(/[\w?)]\z/)
                out << "-"
                literals << number(m[:number][1..])
              else
                literals << number(m[:number])
              end
              "?"
            elsif m[:space]
              " "
            else
              m[:other]
            end
          next if piece == " " && (out.empty? || out.end_with?(" "))

          out << piece
          previous = out
        end
        {"sql" => out.strip, "literals" => literals}
      end

      def number(text)
        text.match?(/[.eE]/) ? Float(text) : Integer(text, 10)
      end
    end
  end
end
