# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "protocol/message"
require_relative "protocol/framing"

module Doubletrack
  # Coordinator ↔ twin protocol. See docs/design/protocol.md.
  #
  # Standard library only (json): this is loaded inside twins after the app's bundle.
  module Protocol
  end
end
