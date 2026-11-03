# frozen_string_literal: true

require "tmpdir"
require "doubletrack/config"

RSpec.describe Doubletrack::Config do
  around { |ex| Dir.mktmpdir { |dir| @dir = dir and ex.run } }

  def load_yaml(text)
    File.write(File.join(@dir, "doubletrack.yml"), text)
    described_class.load(@dir)
  end

  it "uses defaults without a file" do
    config = described_class.load(@dir)
    expect(config.gemfile).to eq(File.join(@dir, "Gemfile"))
    expect(config.request_timeout).to eq(120.0)
  end

  {
    "a non-numeric timeout" => ["request_timeout: soon\n", /request_timeout must be a positive number/],
    "a zero timeout" => ["boot_timeout: 0\n", /boot_timeout must be a positive number/],
    "an empty path" => ["sessions:\n", /sessions must be a path/],
    "a date value (not allowed by safe_load)" => ["baseline: 2026-11-03\n", /doubletrack\.yml/],
    "an alias" => ["a: &x 1\nb: *x\n", /doubletrack\.yml/]
  }.each do |label, (yaml, message)|
    it "rejects #{label} with a ConfigError" do
      expect { load_yaml(yaml) }.to raise_error(Doubletrack::ConfigError, message)
    end
  end
end
