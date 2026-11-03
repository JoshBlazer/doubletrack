# frozen_string_literal: true

require_relative "errors"
require_relative "normalize/trace"
require_relative "diff/difference"
require_relative "diff/structural"
require_relative "diff/noise_mask"
require_relative "diff/severity"
require_relative "diff/fingerprint"
require_relative "diff/cluster"
require_relative "diff/analyzer"

module Doubletrack
  # Structural diff, three-way noise mask, fingerprints, clustering and severity
  # (docs/design/diff.md). Coordinator side; pure Ruby over normalized traces.
  module Diff
  end
end
