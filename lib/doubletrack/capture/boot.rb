# frozen_string_literal: true

# Loaded with `ruby -r<this file> SCRIPT ARGS` by `doubletrack capture`, in the app's test
# process (docs/design/capture.md, ADR 0025). Sets up the app's bundle first, so nothing
# here activates a gem version the app doesn't use, then registers lazy load hooks.
if ENV["DOUBLETRACK_CAPTURE_DIR"]
  require "bundler/setup"
  require "active_support/lazy_load_hooks"
  require_relative "probe"
  Doubletrack::Capture::Probe.register
end
