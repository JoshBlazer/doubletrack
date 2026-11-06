# frozen_string_literal: true

require "doubletrack/ruby_locator"
require "fileutils"
require "rbconfig"
require "tmpdir"

RSpec.describe Doubletrack::RubyLocator do
  around { |ex| Dir.mktmpdir("dt-rubies") { |dir| @home = dir and ex.run } }

  # A fake installed Ruby: bin/ruby is a script that answers the version probe.
  def install(dir, version)
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    ruby = File.join(bin, "ruby")
    File.write(ruby, "#!/bin/sh\nprintf '%s' '#{version}'\n")
    File.chmod(0o755, ruby)
    ruby
  end

  let(:env) { {"HOME" => @home} }

  describe ".find" do
    it "finds a version in rbenv, asdf, mise, chruby, rvm and the CI tool cache" do
      {
        File.join(@home, ".rbenv/versions/3.3.6") => "3.3.6",
        File.join(@home, ".asdf/installs/ruby/3.2.5") => "3.2.5",
        File.join(@home, ".local/share/mise/installs/ruby/3.1.6") => "3.1.6",
        File.join(@home, ".rubies/ruby-3.0.7") => "3.0.7",
        File.join(@home, ".rvm/rubies/ruby-2.7.8") => "2.7.8",
        File.join(@home, "toolcache/Ruby/4.0.9/x64") => "4.0.9"
      }.each { |dir, v| install(dir, v) }
      env["RUNNER_TOOL_CACHE"] = File.join(@home, "toolcache")

      %w[3.3.6 3.2.5 3.1.6 3.0.7 2.7.8 4.0.9].each do |v|
        expect(described_class.find(v, env: env)).to end_with("/bin/ruby"), v
      end
      expect(described_class.find("ruby-3.3.6", env: env)).to include(".rbenv/versions/3.3.6")
    end

    it "honors RBENV_ROOT and skips a directory whose ruby reports another version" do
      install(File.join(@home, "custom-rbenv/versions/3.3.6"), "3.3.5")
      env["RBENV_ROOT"] = File.join(@home, "custom-rbenv")
      expect(described_class.find("3.3.6", env: env)).to be_nil
      install(File.join(@home, "custom-rbenv/versions/3.3.6"), "3.3.6")
      expect(described_class.find("3.3.6", env: env)).to include("custom-rbenv")
    end
  end

  describe ".resolve" do
    let(:app) { File.join(@home, "app").tap { |d| FileUtils.mkdir_p(d) } }

    it "uses the current Ruby for current, and for auto without a .ruby-version" do
      expect(described_class.resolve("current", app_root: app, env: env)).to include("path" => RbConfig.ruby, "version" => RUBY_VERSION, "source" => "current")
      expect(described_class.resolve("auto", app_root: app, env: env)).to include("path" => RbConfig.ruby, "source" => "current")
    end

    it "uses the app's .ruby-version for auto when it's installed, and the current Ruby otherwise" do
      ruby = install(File.join(@home, ".rbenv/versions/3.3.6"), "3.3.6")
      File.write(File.join(app, ".ruby-version"), "ruby-3.3.6\n")
      expect(described_class.resolve("auto", app_root: app, env: env)).to eq("path" => ruby, "version" => "3.3.6", "source" => ".ruby-version")
      File.write(File.join(app, ".ruby-version"), "9.9.9\n")
      expect(described_class.resolve("auto", app_root: app, env: env)).to include("path" => RbConfig.ruby, "source" => "current", "wanted" => "9.9.9")
    end

    it "takes a version or a path, and names the places searched when a version isn't installed" do
      ruby = install(File.join(@home, ".rbenv/versions/3.3.6"), "3.3.6")
      expect(described_class.resolve("3.3.6", app_root: app, env: env)).to eq("path" => ruby, "version" => "3.3.6", "source" => "config")
      expect(described_class.resolve(ruby, app_root: app, env: env)).to include("path" => ruby, "version" => "3.3.6")
      expect { described_class.resolve("9.9.9", app_root: app, env: env) }
        .to raise_error(Doubletrack::ConfigError, /Ruby 9\.9\.9 isn't installed.*\.rbenv\/versions/m)
    end
  end
end
