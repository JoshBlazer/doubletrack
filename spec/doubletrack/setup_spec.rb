# frozen_string_literal: true

require "doubletrack/setup"
require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe Doubletrack::Setup do
  def lock_text
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (8.0.5.1)
            railties (= 8.0.5.1)
          railties (8.0.5.1)
          sqlite3 (2.7.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails (~> 8.0.5)
        sqlite3 (>= 2.1)

      BUNDLED WITH
         2.6.9
    LOCK
  end

  def git_lock_text
    <<~LOCK
      GIT
        remote: https://github.com/rails/rails.git
        revision: e3d5c569d217c56c022b04acb127a8c24dbe9685
        branch: main
        specs:
          rails (8.2.0.alpha)

      GEM
        remote: https://rubygems.org/
        specs:

      PLATFORMS
        ruby

      DEPENDENCIES
        rails!

      BUNDLED WITH
         2.6.9
    LOCK
  end

  describe ".next_requirement" do
    it "defaults to the next minor version and accepts a minor, a patch or main" do
      expect(described_class.next_requirement("8.0.5.1", nil)).to eq('"~> 8.1.0"')
      expect(described_class.next_requirement("7.2.2", nil)).to eq('"~> 8.0.0"')
      expect(described_class.next_requirement("8.0.5.1", "8.1")).to eq('"~> 8.1.0"')
      expect(described_class.next_requirement("8.0.5.1", "8.1.2")).to eq('"~> 8.1.2"')
      expect(described_class.next_requirement("8.1.4", "main")).to eq('github: "rails/rails", branch: "main"')
    end

    it "refuses a target that isn't newer, or isn't a version" do
      expect { described_class.next_requirement("8.1.4", "8.0") }.to raise_error(Doubletrack::ConfigError, /not newer than 8.1.4/)
      expect { described_class.next_requirement("8.1.4", "latest") }.to raise_error(Doubletrack::ConfigError, /--to/)
    end
  end

  describe ".rewrite_rails" do
    it "replaces a one-line rails statement and keeps everything else" do
      text = %(source "https://rubygems.org"\n\ngem 'rails', '~> 8.0.5' # the framework\ngem "sqlite3"\n)
      expect(described_class.rewrite_rails(text, '"~> 8.1.0"')).to eq(%(source "https://rubygems.org"\n\ngem "rails", "~> 8.1.0" # the framework\ngem "sqlite3"\n))
    end

    it "replaces a statement continued over several lines" do
      text = %(gem "rails",\n  github: "rails/rails",\n  branch: "main"\ngem "puma"\n)
      expect(described_class.rewrite_rails(text, '"~> 8.2.0"')).to eq(%(gem "rails", "~> 8.2.0"\ngem "puma"\n))
    end

    it "explains when there is no rails statement to replace" do
      expect { described_class.rewrite_rails(%(gem "railties"\n), '"~> 8.1.0"') }.to raise_error(Doubletrack::ConfigError, /no `gem "rails"`/)
    end
  end

  describe ".locked_rails" do
    it "reads a released version, or a version and git revision" do
      expect(described_class.locked_rails(lock_text)).to eq(["8.0.5.1", nil])
      expect(described_class.locked_rails(git_lock_text)).to eq(["8.2.0.alpha", "e3d5c569d217c56c022b04acb127a8c24dbe9685"])
    end
  end

  describe ".init" do
    around { |ex| Dir.mktmpdir("dt-init") { |dir| @app = dir and ex.run } }

    let(:out) { StringIO.new }

    def write(name, text) = File.write(File.join(@app, name), text)

    before do
      write("Gemfile", %(source "https://rubygems.org"\ngem "rails", "~> 8.0.5"\ngem "sqlite3", ">= 2.1"\n))
      write("Gemfile.lock", lock_text)
    end

    it "writes Gemfile.next as a copy with the next Rails, copies the lockfile, and leaves Gemfile alone" do
      gemfile = File.read(File.join(@app, "Gemfile"))
      result = described_class.init(@app, out: out)

      expect(result).to include("from" => "8.0.5.1", "requirement" => '"~> 8.1.0"', "mode" => "copy")
      next_gemfile = File.read(File.join(@app, "Gemfile.next"))
      expect(next_gemfile).to include("doubletrack init", %(gem "rails", "~> 8.1.0"), %(gem "sqlite3", ">= 2.1"))
      expect(File.read(File.join(@app, "Gemfile.next.lock"))).to eq(lock_text)
      expect(File.read(File.join(@app, "Gemfile"))).to eq(gemfile)
      expect(File).to exist(File.join(@app, "doubletrack", "sessions", "README.md"))
      expect(out.string).to include("BUNDLE_GEMFILE=Gemfile.next bundle install", "doubletrack doctor", "doubletrack capture", "doubletrack run")
    end

    it "symlinks Gemfile.next when the Gemfile already branches on next? (next_rails convention)" do
      write("Gemfile", %(def next?\n  File.basename(__FILE__) == "Gemfile.next"\nend\nif next?\n  gem "rails", "~> 8.1.4"\nelse\n  gem "rails", "~> 8.0.5"\nend\n))
      result = described_class.init(@app, out: out)
      expect(result["mode"]).to eq("symlink")
      expect(File.readlink(File.join(@app, "Gemfile.next"))).to eq("Gemfile")
      expect(out.string).to include("if next?")
    end

    it "never overwrites an existing Gemfile.next unless forced" do
      write("Gemfile.next", "mine\n")
      expect { described_class.init(@app, out: out) }.to raise_error(Doubletrack::ConfigError, /Gemfile.next already exists.*--force/)
      expect(File.read(File.join(@app, "Gemfile.next"))).to eq("mine\n")
      described_class.init(@app, out: out, force: true)
      expect(File.read(File.join(@app, "Gemfile.next"))).to include("~> 8.1.0")
    end

    it "needs a Gemfile.lock to know the current Rails" do
      FileUtils.rm(File.join(@app, "Gemfile.lock"))
      expect { described_class.init(@app, out: out) }.to raise_error(Doubletrack::ConfigError, /Gemfile.lock not found.*bundle install/)
    end
  end
end
