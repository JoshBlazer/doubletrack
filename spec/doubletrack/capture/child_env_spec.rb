# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "doubletrack/capture"

RSpec.describe "Doubletrack::Capture child process" do
  # Bundler re-execs `bin/rails test` with the same script and arguments, but not Ruby's
  # -r flags, when the lockfile was written by another Bundler version. RUBYOPT is kept.
  it "loads the probe through RUBYOPT, which survives Bundler's re-exec" do
    env = Doubletrack::Capture.child_env(dir: "/tmp/cap", gemfile: "/app/Gemfile")
    expect(env).to include("BUNDLE_GEMFILE" => "/app/Gemfile", "RAILS_ENV" => "test", "DOUBLETRACK_CAPTURE_DIR" => "/tmp/cap",
      "RUBYOPT" => "-r#{Doubletrack::Capture::BOOT}", "RUBYLIB" => nil)
  end

  it "falls back to no RUBYOPT when the probe path has whitespace (RUBYOPT can't quote)" do
    stub_const("Doubletrack::Capture::BOOT", "/my gems/doubletrack/capture/boot.rb")
    expect(Doubletrack::Capture.child_env(dir: "/tmp/cap", gemfile: "/app/Gemfile")).to include("RUBYOPT" => nil)
  end

  # RUBYOPT reaches every Ruby subprocess the tests start, also ones outside any bundle.
  it "leaves a Ruby process without a bundle alone" do
    Dir.mktmpdir do |dir|
      env = {"DOUBLETRACK_CAPTURE_DIR" => dir, "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"), "RUBYOPT" => nil, "RUBYLIB" => nil}
      out, status = Bundler.with_unbundled_env { Open3.capture2e(env, RbConfig.ruby, "-r#{Doubletrack::Capture::BOOT}", "-e", "puts :ok", chdir: dir) }
      expect([out, status.success?]).to eq(["ok
", true])
    end
  end
end
