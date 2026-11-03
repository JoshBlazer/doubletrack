# frozen_string_literal: true

# Kept in its own file with no requires: the twin loads it *before* the app's bundle,
# to report boot failures with the right schema_version.
module Doubletrack
  module Protocol
    # Incremented on every incompatible change to the envelope or any payload.
    # v2 (ADR 0013): run_session returns traces[] and accepts http_stubs[].
    SCHEMA_VERSION = 2
  end
end
