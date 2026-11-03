# frozen_string_literal: true

require "fileutils"
require "doubletrack/specgen"

RSpec.describe "Doubletrack::Specgen.framework" do
  def framework(dir, setting) = Doubletrack::Specgen.framework(dir, setting)

  it "auto: picks RSpec when the app has spec/ and rspec-core in Gemfile.lock" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "spec"))
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    rspec-core (3.13.6)\n")
      expect(framework(dir, "auto")).to eq("rspec")
    end
  end

  it "auto: picks Minitest without spec/ or without rspec-core" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    rspec-core (3.13.6)\n")
      expect(framework(dir, "auto")).to eq("minitest")
      FileUtils.mkdir_p(File.join(dir, "spec"))
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    minitest (5.25.5)\n")
      expect(framework(dir, "auto")).to eq("minitest")
    end
  end

  it "honors an explicit setting and rejects unknown ones" do
    Dir.mktmpdir do |dir|
      expect(framework(dir, "rspec")).to eq("rspec")
      expect(framework(dir, "minitest")).to eq("minitest")
      expect { framework(dir, "cucumber") }.to raise_error(Doubletrack::ConfigError, /repro_framework/)
    end
  end
end
