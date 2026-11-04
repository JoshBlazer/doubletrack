# frozen_string_literal: true

require_relative "errors"

module Doubletrack
  # How a twin's Rails is named, and the dual-boot version check (RISKS R1).
  #
  # Apps that track Rails main (or any git ref) report the same Rails.version on both
  # sides of an upgrade, e.g. 8.2.0.alpha → 8.2.0.alpha; the git revision the twin loaded
  # tells them apart (hello's "rails_revision", nil for a released gem).
  module RailsLabel
    SHORT = 10

    module_function

    # @param twin [Hash, nil] a hello payload or run.json "twins" entry
    # @return [String] "8.1.4", or "8.2.0.alpha (1a02651ac3)" for Rails from git
    def label(twin)
      return "" unless twin

      version = twin["rails_version"].to_s
      revision = twin["rails_revision"].to_s
      revision.empty? ? version : "#{version} (#{revision[0, SHORT]})"
    end

    # Raises unless the controls run the same Rails and the candidate a different one.
    def check!(control_a, control_a_prime, candidate_b)
      a, a_prime, b = [control_a, control_a_prime, candidate_b].map { |t| label(t) }
      raise Error, "control A (#{a}) and control A′ (#{a_prime}) must run the same Rails version" unless a == a_prime
      raise Error, "dual boot not effective: candidate B also loaded Rails #{b} (RISKS R1)" if a == b
    end

    # In a twin: the git revision of the loaded Rails, or nil for a released gem.
    def loaded_revision
      source = Gem.loaded_specs["rails"]&.source || Gem.loaded_specs["railties"]&.source
      revision = source.revision if source.respond_to?(:revision)
      (revision.is_a?(String) && revision.match?(/\A\h{7,40}\z/)) ? revision : nil
    rescue
      nil
    end
  end
end
