# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# M8 exit check, part 1 (ADR 0033, 0034): `init` sets up dual boot on an app that has
# none, and `doctor` passes it, booting both Rails versions.
RSpec.describe "doubletrack init and doctor on a copy of shop", :integration do
  root = File.expand_path("../..", __dir__)

  def cli(root, *args)
    Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), *args, chdir: root)
  end

  before(:all) do
    @tmp = Dir.mktmpdir("doubletrack-m8-")
    @app = File.join(@tmp, "shop")
    FileUtils.mkdir_p(@app)
    source = File.join(root, "fixtures/apps/shop")
    (Dir.children(source) - %w[tmp log Gemfile.next Gemfile.next.lock vendor .bundle]).each do |entry|
      FileUtils.cp_r(File.join(source, entry), @app)
    end
    # A plain Gemfile on Rails 8.0, with no dual boot: what a user starts from.
    gemfile = File.read(File.join(source, "Gemfile"))
      .sub(/^def next\?.*?^end\n\nif next\?\n.*?^end\n/m, %(gem "rails", "~> 8.0.5"\n))
      .sub(%(path: "../../.."), %(path: #{root.inspect}))
    File.write(File.join(@app, "Gemfile"), gemfile)
    lock = File.read(File.join(source, "Gemfile.lock")).sub("remote: ../../..", "remote: #{root}")
    File.write(File.join(@app, "Gemfile.lock"), lock)
    @init_out, @init_err, @init_status = cli(root, "init", @app, "--to", "8.1", "--install")
    @doctor_out, @doctor_err, @doctor_status = cli(root, "doctor", @app)
  end

  after(:all) { FileUtils.rm_rf(@tmp) }

  it "writes Gemfile.next for Rails 8.1 and installs it, leaving Gemfile alone" do
    expect(@init_status.exitstatus).to eq(0), "#{@init_out}\n#{@init_err}"
    expect(File.read(File.join(@app, "Gemfile"))).to include(%(gem "rails", "~> 8.0.5"))
    expect(File.read(File.join(@app, "Gemfile.next"))).to include(%(gem "rails", "~> 8.1.0"))
    expect(File.read(File.join(@app, "Gemfile.next.lock"))).to match(/^    rails \(8\.1\.[\d.]+\)$/) # the newest 8.1 patch
  end

  it "passes doctor, which boots both versions" do
    expect(@doctor_status.exitstatus).to eq(0), "#{@doctor_out}\n#{@doctor_err}"
    expect(@doctor_out).to match(/ok    boot: control A booted Rails 8\.0\.\S+ in [\d.]+ s, candidate B Rails 8\.1\.\S+ in [\d.]+ s/)
    expect(@doctor_out).to include("ok    rails versions: 8.0.5.1 → 8.1.")
  end

  it "fails doctor once the next lockfile is gone, naming the fix" do
    lock = File.join(@app, "Gemfile.next.lock")
    FileUtils.mv(lock, "#{lock}.aside")
    out, err, status = cli(root, "doctor", @app, "--no-boot")
    expect(status.exitstatus).to eq(1), "#{out}\n#{err}"
    expect(out).to include("FAIL  dual boot: missing Gemfile.next.lock", "fix: BUNDLE_GEMFILE=Gemfile.next bundle install")
  ensure
    FileUtils.mv("#{lock}.aside", lock) if lock && File.exist?("#{lock}.aside")
  end
end
