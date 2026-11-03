# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::Structural do
  def diff(a, b) = described_class.call(a, b)

  it "reports changed, added and removed leaves with paths" do
    a = {"response" => {"status" => 200, "headers" => {"x" => "1"}}, "jobs" => [{"q" => "a"}]}
    b = {"response" => {"status" => 500, "headers" => {"y" => "2"}}, "jobs" => [{"q" => "a"}, {"q" => "b"}]}
    out = diff(a, b).map { |d| [d.path_string, d.op, d.a, d.b] }
    expect(out).to contain_exactly(
      ["response.status", "changed", 200, 500],
      ["response.headers.x", "removed", "1", nil],
      ["response.headers.y", "added", nil, "2"],
      ["jobs[1]", "added", nil, {"q" => "b"}]
    )
  end

  it "reports a type change once, without descending" do
    out = diff({"body" => {"json" => {"a" => 1}}}, {"body" => {"text" => "x"}})
    expect(out.map(&:path_string)).to contain_exactly("body.json", "body.text")
    expect(diff({"x" => [1]}, {"x" => {"a" => 1}}).map { |d| [d.path_string, d.op] }).to eq([["x", "changed"]])
  end

  it "distinguishes 1 from 1.0 and nil from missing" do
    expect(diff({"a" => 1}, {"a" => 1.0}).size).to eq(1)
    expect(diff({"a" => nil}, {}).map(&:op)).to eq(["removed"])
  end

  it "generalizes array indices" do
    d = diff({"sql_writes" => [{"binds" => {"n" => 1}}]}, {"sql_writes" => [{"binds" => {"n" => 2}}]}).first
    expect(d.path_string).to eq("sql_writes[0].binds.n")
    expect(d.generalized).to eq("sql_writes[*].binds.n")
  end

  describe "properties" do
    random = Random.new(11)
    gen = ->(depth) {
      case (depth > 3) ? random.rand(3) : random.rand(5)
      when 0 then random.rand(5)
      when 1 then ["a", "b", nil, true][random.rand(4)]
      when 2 then random.rand(3).zero? ? 1.0 : "s"
      when 3 then Array.new(random.rand(4)) { gen.call(depth + 1) }
      else Array.new(random.rand(4)) { ["k#{random.rand(4)}", gen.call(depth + 1)] }.to_h
      end
    }

    it "finds no differences between a value and itself" do
      200.times do
        v = gen.call(0)
        expect(diff(v, Marshal.load(Marshal.dump(v)))).to eq([])
      end
    end

    it "applying the diff to A reproduces B" do
      300.times do
        a = {"root" => gen.call(0)}
        b = {"root" => gen.call(0)}
        expect(described_class.apply(a, diff(a, b))).to eq(b)
      end
    end
  end
end
