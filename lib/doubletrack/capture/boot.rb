# frozen_string_literal: true

# Loaded through RUBYOPT=-r<this file> by `doubletrack capture`, in the app's test process
# (docs/design/capture.md, ADR 0025, ADR 0028). RUBYOPT, unlike a command-line -r, survives
# Bundler re-executing the process with the lockfile's Bundler version. It also reaches
# every Ruby subprocess the tests start, so this file must never break one: outside a
# loadable bundle it does nothing.
#
# Sets up the app's bundle first, so nothing here activates a gem version the app doesn't
# use, then registers lazy load hooks.
if ENV["DOUBLETRACK_CAPTURE_DIR"]
  begin
    require "bundler/setup"
    require "active_support/lazy_load_hooks"
  rescue LoadError, StandardError
    # Not the app's bundle (a subprocess elsewhere, or a bundle without Active Support).
  else
    require_relative "probe"
    Doubletrack::Capture::Probe.register
  end
end
