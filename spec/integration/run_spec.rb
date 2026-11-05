# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# M3 exit check, part 1: `doubletrack run` on shop produces results and a report.
RSpec.describe "doubletrack run on fixtures/apps/shop", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  def run_cli(root, *args)
    Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), *args, chdir: root)
  end

  before(:all) do
    @out = Dir.mktmpdir("doubletrack-m3-")
    @stdout, @stderr, @status = run_cli(root, "run", shop, "--out", @out, "--seed", "42")
    @results = Dir.glob(File.join(@out, "*")).find { |d| File.directory?(d) }
  end

  after(:all) { FileUtils.rm_rf(@out) }

  it "exits 0 (no findings) or 1 (findings), never 2" do
    expect([0, 1]).to include(@status.exitstatus), "#{@stdout}\n#{@stderr}"
  end

  it "writes run.json with seed, versions, coverage and noise statistics" do
    run = JSON.parse(File.read(File.join(@results, "run.json")))
    expect(run).to include("run_version" => 1, "seed" => 42)
    expect(run["run_id"]).to end_with("-42")
    expect(run.dig("twins", "control_a", "rails_version")).to start_with("8.0.")
    expect(run.dig("twins", "control_a_prime", "rails_version")).to eq(run.dig("twins", "control_a", "rails_version"))
    expect(run.dig("twins", "candidate_b", "rails_version")).to start_with("8.1.")
    expect(run.dig("coverage", "routes_total")).to be > 0
    expect(run["sessions"].size).to be >= 3
    expect(run["noise"]).to include("a_vs_a_prime_differences", "suppressed", "masked_paths")
    expect(run["verdict"]).to eq((run.dig("counts", "data-changing") + run.dig("counts", "user-visible")).zero? ? "ready" : "not_ready")
    expect(@status.exitstatus).to eq(run.dig("counts", "findings").zero? ? 0 : 1)
  end

  it "writes raw traces for all three twins and findings.json" do
    session_dirs = Dir.glob(File.join(@results, "traces", "*"))
    expect(session_dirs).not_to be_empty
    expect(Dir.children(session_dirs.first).sort).to eq(%w[candidate_b.json control_a.json control_a_prime.json])
    findings = JSON.parse(File.read(File.join(@results, "findings.json")))
    expect(findings).to include("findings_version" => 2, "changes" => an_instance_of(Array))
    expect(File.read(File.join(@results, "summary.md"))).to start_with("<!-- doubletrack-summary -->") # M9
  end

  it "writes the static report and prints its path with a severity summary" do
    expect(File).to exist(File.join(@results, "report", "index.html"))
    expect(@stdout).to include("report/index.html")
    expect(@stdout).to match(/data-changing \d+.*user-visible \d+.*cosmetic \d+/m)
  end

  it "regenerates the same findings from stored traces with `doubletrack report`" do
    before = File.read(File.join(@results, "findings.json"))
    _, err, status = run_cli(root, "report", @results)
    expect(status.exitstatus).to eq(1), err # same exit codes as run: shop has one new finding
    expect(File.read(File.join(@results, "findings.json"))).to eq(before)
  end
end
