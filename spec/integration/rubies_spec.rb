# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# M11 exit check (ADR 0038): candidate B on another Ruby than control A. Runs when
# DOUBLETRACK_NEXT_RUBY names a second installed Ruby (a version or a path) and shop's
# Gemfile.next bundle is installed for it (CI job "integration two Rubies").
RSpec.describe "doubletrack run with candidate B on another Ruby", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  before(:all) do
    skip "set DOUBLETRACK_NEXT_RUBY to a second installed Ruby to run this check" if ENV["DOUBLETRACK_NEXT_RUBY"].to_s.empty?

    @tmp = Dir.mktmpdir("doubletrack-m11-")
    @stdout, @stderr, @status = Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), "run", shop,
      "--out", File.join(@tmp, "runs"), "--seed", "42", "--baseline", File.join(@tmp, "baseline.yml"),
      "--next-ruby", ENV["DOUBLETRACK_NEXT_RUBY"], chdir: root)
    @results = Dir.glob(File.join(@tmp, "runs", "*")).find { |d| File.directory?(d) }
    @run = JSON.parse(File.read(File.join(@results, "run.json"))) if @results
  end

  after(:all) { FileUtils.rm_rf(@tmp) if @tmp }

  it "boots the controls on this Ruby and the candidate on the other one" do
    expect(@status.exitstatus).to eq(1), "#{@stdout}\n#{@stderr}"
    expect(@run.dig("twins", "control_a", "ruby_version")).to eq(RUBY_VERSION)
    expect(@run.dig("twins", "control_a_prime", "ruby_version")).to eq(RUBY_VERSION)
    expect(@run.dig("twins", "candidate_b", "ruby_version")).not_to eq(RUBY_VERSION)
    expect(@stderr).to match(/candidate B \(Gemfile\.next on Ruby \d/)
  end

  it "still finds shop's change, with a verified reproduction" do
    findings = JSON.parse(File.read(File.join(@results, "findings.json")))["findings"]
    expect(findings.map { |f| f["id"] }).to include("f-bb3068808cf1")
    repros = JSON.parse(File.read(File.join(@results, "repros.json")))["repros"]
    expect(repros.find { |r| r["finding_id"] == "f-bb3068808cf1" }["status"]).to eq("reproduced")
  end
end
