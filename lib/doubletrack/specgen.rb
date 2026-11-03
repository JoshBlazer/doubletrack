# frozen_string_literal: true

require_relative "errors"
require_relative "repro"
require_relative "specgen/writer"
require_relative "specgen/minimizer"
require_relative "specgen/generator"

module Doubletrack
  # Reproduction specs (docs/design/specgen.md): minimize and verify on the live twins
  # (Generator), render RSpec or Minitest files (Writer).
  module Specgen
    FRAMEWORKS = %w[rspec minitest].freeze
    SETTINGS = (["auto"] + FRAMEWORKS).freeze

    module_function

    # @param app_root [String]
    # @param setting [String] "auto", "rspec" or "minitest"
    # @return [String] "rspec" or "minitest"
    def framework(app_root, setting)
      raise ConfigError, "repro_framework must be one of #{SETTINGS.join(", ")} (got #{setting.inspect})" unless SETTINGS.include?(setting)
      return setting unless setting == "auto"

      lock = File.join(app_root, "Gemfile.lock")
      rspec = File.directory?(File.join(app_root, "spec")) && File.exist?(lock) && File.read(lock).match?(/^\s+rspec-core \(/)
      rspec ? "rspec" : "minitest"
    end

    # Directory of generated files inside results/<run_id>, by framework.
    def relative_dir(framework)
      (framework == "rspec") ? "repro/spec/doubletrack" : "repro/test/doubletrack"
    end

    def file_name(framework, finding_id)
      (framework == "rspec") ? "#{finding_id}_spec.rb" : "#{finding_id}_test.rb"
    end
  end
end
