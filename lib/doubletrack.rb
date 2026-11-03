# frozen_string_literal: true

require_relative "doubletrack/version"
require_relative "doubletrack/errors"
require_relative "doubletrack/protocol"
require_relative "doubletrack/coordinator/twin_process"
require_relative "doubletrack/session"

# Doubletrack replays traffic against a Rails app on two Rails versions side by side and
# reports behavioral differences. See docs/PRODUCT.md.
module Doubletrack
  # CLI exit codes (docs/PRODUCT.md#cli).
  EXIT_OK = 0
  EXIT_DIFFERENCES = 1
  EXIT_ERROR = 2
end
