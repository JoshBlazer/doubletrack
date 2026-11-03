# frozen_string_literal: true

module Doubletrack
  module Diff
    # Severity rules, in one place (ADR 0018, docs/design/diff.md#severity).
    module Severity
      DATA_CHANGING = "data-changing"
      USER_VISIBLE = "user-visible"
      COSMETIC = "cosmetic"
      ORDER = [DATA_CHANGING, USER_VISIBLE, COSMETIC].freeze
      DATA_CHANNELS = %w[sql_writes jobs mail cache http].freeze
      USER_VISIBLE_HEADERS = %w[location content-type].freeze

      module_function

      # @param path [Array<String, Integer>] a difference path
      # @return [String] one of {ORDER}
      def classify(path)
        head = path.first
        case head
        when *DATA_CHANNELS then sql_text?(path) ? COSMETIC : DATA_CHANGING
        when "performed_jobs" then sql_text?(path.drop(2)) ? COSMETIC : DATA_CHANGING
        when "performed_jobs_truncated" then DATA_CHANGING
        when "exception", "session" then USER_VISIBLE
        when "response" then response(path.drop(1))
        else COSMETIC
        end
      end

      # The SQL text alone changed: ["sql_writes", i, "sql"].
      def sql_text?(path)
        path.size == 3 && path[0] == "sql_writes" && path[2] == "sql"
      end

      def response(rest)
        return USER_VISIBLE if rest.empty? # the response appeared or disappeared

        case rest.first
        when "status", "body", "set_cookies" then USER_VISIBLE
        when "headers" then (rest.size > 1 && USER_VISIBLE_HEADERS.include?(rest[1])) ? USER_VISIBLE : COSMETIC
        else COSMETIC
        end
      end

      # @param severities [Array<String>]
      # @return [String, nil] the most severe
      def max(severities)
        severities.min_by { |s| ORDER.index(s) }
      end
    end
  end
end
