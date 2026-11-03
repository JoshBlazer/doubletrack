# Doubletrack eval fixture (ADR 0020). This file is the ONLY difference between
# fixtures/apps/planted/changes (ENABLED = true) and fixtures/apps/planted/clean
# (ENABLED = false). When enabled, each planted behavior switches on under Rails >= 8.1
# only, simulating an upgrade that changes behavior. Expected findings:
# doubletrack/expected.yml.
module Planted
  ENABLED = false

  def self.on?
    ENABLED && Rails.gem_version >= Gem::Version.new("8.1")
  end
end
