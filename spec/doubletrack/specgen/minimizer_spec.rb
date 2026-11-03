# frozen_string_literal: true

require "doubletrack/specgen"

RSpec.describe Doubletrack::Specgen::Minimizer do
  def req(path) = {"method" => "GET", "path" => path, "offset_ms" => 0}

  # A fake three-way replay: A and A′ always give "old"; B gives "new" only if every
  # path in `needs` was replayed before the last request.
  def oracle(needs, calls)
    lambda do |requests|
      calls << requests.map { |r| r["path"] }
      paths = requests[0...-1].map { |r| r["path"] }
      b = (needs.all? { |n| paths.include?(n) }) ? "new" : "old"
      {"control_a" => "old", "control_a_prime" => "old", "candidate_b" => b}
    end
  end

  it "keeps only the earlier requests the difference needs, plus the finding's request" do
    calls = []
    requests = %w[/a /setup /c /target].map { |p| req(p) }
    result = described_class.new(replay: oracle(["/setup"], calls)).call(requests: requests, expected: "old")
    expect(result.status).to eq("reproduced")
    expect(result.requests.map { |r| r["path"] }).to eq(%w[/setup /target])
    expect(result.kept).to eq([1, 3])
    expect(result.observed).to eq("control_a" => "old", "control_a_prime" => "old", "candidate_b" => "new")
    expect(calls.first).to eq(%w[/a /setup /c /target]) # the full prefix is verified first
  end

  it "returns not_reproduced after one replay, without minimizing, when the full prefix doesn't reproduce" do
    calls = []
    result = described_class.new(replay: oracle(["/never"], calls)).call(requests: [req("/a"), req("/t")], expected: "old")
    expect(result.status).to eq("not_reproduced")
    expect(result.requests.size).to eq(2)
    expect(result.kept).to eq([0, 1])
    expect(calls.size).to eq(1)
  end

  it "needs no minimization for a single request" do
    calls = []
    result = described_class.new(replay: oracle([], calls)).call(requests: [req("/t")], expected: "old")
    expect(result.status).to eq("reproduced")
    expect(result.kept).to eq([0])
    expect(calls.size).to eq(1)
  end

  it "stops after max_steps removal attempts and keeps the requests it didn't try (latest tried first)" do
    calls = []
    requests = %w[/1 /2 /3 /4 /5 /t].map { |p| req(p) }
    result = described_class.new(replay: oracle([], calls), max_steps: 2).call(requests: requests, expected: "old")
    expect(calls.size).to eq(3) # verify + 2 attempts
    expect(result.requests.map { |r| r["path"] }).to eq(%w[/1 /2 /3 /t])
    expect(result.kept).to eq([0, 1, 2, 5])
  end

  it "keeps the observed values of the last successful replay" do
    flips = 0
    replay = lambda do |requests|
      flips += 1
      {"control_a" => "old", "control_a_prime" => "old", "candidate_b" => "new-#{requests.size}"}
    end
    result = described_class.new(replay: replay).call(requests: [req("/a"), req("/t")], expected: "old")
    expect(result.requests.size).to eq(1)
    expect(result.observed["candidate_b"]).to eq("new-1")
  end
end
