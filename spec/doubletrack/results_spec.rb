# frozen_string_literal: true

require "json"
require "tmpdir"
require "doubletrack/results"
require "doubletrack/baseline"
require_relative "../support/results_fixture"

RSpec.describe Doubletrack::Results do
  around { |ex| Dir.mktmpdir { |dir| @tmp = dir and ex.run } }

  let(:baseline_path) { File.join(@tmp, "app", "doubletrack.baseline.yml") }
  let(:dir) { File.join(@tmp, "results", "20261103T000000Z-1") }

  before do
    FileUtils.mkdir_p(File.dirname(baseline_path))
    ResultsFixture.build(dir, app_root: File.join(@tmp, "app"), baseline_path: baseline_path)
  end

  def analyze = described_class.analyze(dir, JSON.parse(File.read(File.join(dir, "run.json"))))

  it "without a baseline: every finding is new and decides the verdict" do
    run, findings = analyze
    expect(findings.size).to eq(1)
    expect(findings.first).not_to have_key("accepted")
    expect(run["counts"]).to include("findings" => 1, "user-visible" => 1, "accepted" => 0)
    expect(run["verdict"]).to eq("not_ready")
    expect(run["baseline"]).to include("path" => baseline_path, "exists" => false, "accepted" => 0, "stale" => [])
  end

  it "with the finding accepted: it is kept and marked, counts and verdict use new findings only" do
    finding = analyze[1].first
    baseline = Doubletrack::Baseline.load(baseline_path)
    baseline.accept(finding, reason: "expected", author: "A", run: {"run_id" => "x"}, now: Time.utc(2026, 11, 3))
    baseline.accept(finding.merge("id" => "f-0000000000aa"), reason: "gone", author: "A", run: {}, now: Time.utc(2026, 11, 3))
    baseline.write

    run, findings = analyze
    expect(findings.first["accepted"]).to include("reason" => "expected")
    expect(run["counts"]).to include("findings" => 0, "user-visible" => 0, "accepted" => 1)
    expect(run["verdict"]).to eq("ready")
    expect(run["baseline"]).to include("exists" => true, "accepted" => 1, "stale" => ["f-0000000000aa"])
    stored = JSON.parse(File.read(File.join(dir, "findings.json")))
    expect(stored["findings"].first["accepted"]).to include("author" => "A")
    expect(File.read(File.join(dir, "report", "index.html"))).to include("1 accepted")
  end

  it "records each occurrence's path as segments, so repros don't re-parse dotted paths" do
    occurrence = analyze[1].first["occurrences"].first
    expect(occurrence["segments"]).to eq(["response", "body", "json", "total"])
  end

  it "fails with a ConfigError on a malformed baseline instead of ignoring it" do
    File.write(baseline_path, "baseline_version: 9\n")
    expect { analyze }.to raise_error(Doubletrack::ConfigError, /baseline/)
  end

  it "re-renders stored reproduction specs from repros.json" do
    finding = analyze[1].first
    repros = {"repros_version" => 1, "run_id" => File.basename(dir), "framework" => "rspec",
              "snapshot" => "snapshots/abc.sqlite3",
              "repros" => [{"finding_id" => finding["id"], "title" => finding["title"], "severity" => "user-visible",
                            "session_id" => "s1", "seed" => 1, "started_at" => "2026-01-01T00:00:00Z", "perform_jobs" => true,
                            "http_stubs" => [], "requests" => [{"method" => "POST", "path" => "/orders", "params" => {}, "headers" => {}, "offset_ms" => 0}],
                            "kept_request_indexes" => [0], "requests_before" => 1, "segments" => ["response", "body", "json", "total"],
                            "op" => "changed", "expected" => 1, "expected_absent" => false,
                            "normalize" => {"ignored_headers" => [], "ignored_columns" => []}, "status" => "reproduced",
                            "observed" => {"control_a" => {"value" => 1}, "control_a_prime" => {"value" => 1}, "candidate_b" => {"value" => 2}}}]}
    File.write(File.join(dir, "repros.json"), JSON.generate(repros))
    analyze
    spec = File.join(dir, "repro", "spec", "doubletrack", "#{finding["id"]}_spec.rb")
    expect(File.read(spec)).to include(%{expect(replay.last.at("response", "body", "json", "total")).to eql(1)})
    page = File.read(File.join(dir, "report", "findings", "#{finding["id"]}.html"))
    expect(page).to include("Verified in this run", "#{finding["id"]}_spec.rb")
    expect(page).not_to include("arrives in milestone M4")

    # After `accept`, `report` must not keep rendering the repro of a finding that is no
    # longer new (the run would not have built one).
    baseline = Doubletrack::Baseline.load(baseline_path)
    baseline.accept(finding, reason: "expected", author: "A", run: {"run_id" => "x"}, now: Time.utc(2026, 11, 3))
    baseline.write
    FileUtils.rm_rf(File.join(dir, "repro"))
    analyze
    expect(File).not_to exist(spec)
    expect(File.read(File.join(dir, "report", "findings", "#{finding["id"]}.html"))).not_to include("Verified in this run")
  end
end
