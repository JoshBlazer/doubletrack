# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::NoiseMask do
  let(:mask) { described_class.new }
  let(:route) { "GET /orders(.:format)" }

  def d(path, op = "changed") = Doubletrack::Diff::Difference.new(path: path, op: op, a: 1, b: 2)

  it "masks the same path and paths below it, on the same route only" do
    mask.add(route, [d(["response", "body", "json", "token"])])
    expect(mask.masked?(route, ["response", "body", "json", "token"])).to be(true)
    expect(mask.masked?(route, ["response", "body", "json", "token", "x"])).to be(true)
    expect(mask.masked?("POST /orders(.:format)", ["response", "body", "json", "token"])).to be(false)
  end

  it "never masks a parent (a change above the noise replaces the subtree)" do
    mask.add(route, [d(["response", "body", "json", "token"])])
    expect(mask.masked?(route, ["response", "body", "json"])).to be(false)
    expect(mask.masked?(route, ["response", "body"])).to be(false)
  end

  it "keeps array indices: noise in one element does not hide its siblings" do
    mask.add(route, [d(["mail", 0, "html_body"])])
    expect(mask.masked?(route, ["mail", 0, "html_body"])).to be(true)
    expect(mask.masked?(route, ["mail", 1, "html_body"])).to be(false)
    expect(mask.masked?(route, ["mail", 0, "subject"])).to be(false)
  end

  it "unions across sessions and reports masked paths and counts" do
    mask.add(route, [d(["a"])])
    mask.add(route, [d(["b"]), d(["a"])])
    expect(mask.paths(route)).to eq(%w[a b])
    expect(mask.observed).to eq(3)
    expect(mask.to_h).to eq(route => %w[a b])
  end

  it "never hides a difference at an unrelated path (property)" do
    random = Random.new(5)
    keys = %w[a b c d]
    300.times do
      m = described_class.new
      noise = Array.new(random.rand(1..3)) { Array.new(random.rand(1..3)) { keys.sample(random: random) } }
      m.add(route, noise.map { |p| d(p) })
      probe = Array.new(random.rand(1..4)) { keys.sample(random: random) }
      related = noise.any? { |p| probe.first(p.size) == p }
      expect(m.masked?(route, probe)).to eq(related)
    end
  end
end
