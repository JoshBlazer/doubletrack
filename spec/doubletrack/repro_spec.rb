# frozen_string_literal: true

require "doubletrack/repro"

RSpec.describe Doubletrack::Repro do
  let(:trace) do
    {
      "response" => {"status" => 200, "headers" => {"content-type" => "text/html"}},
      "sql_writes" => [{"table" => "users", "binds" => {"name" => "Ada"}}],
      "note" => nil
    }
  end

  describe ".lookup" do
    it "digs through hash keys and array indexes" do
      expect(described_class.lookup(trace, ["sql_writes", 0, "binds", "name"])).to eq("Ada")
      expect(described_class.lookup(trace, ["response", "status"])).to eq(200)
    end

    it "returns nil for a present null and the whole trace for no segments" do
      expect(described_class.lookup(trace, ["note"])).to be_nil
      expect(described_class.lookup(trace, [])).to eq(trace)
    end

    it "returns ABSENT for a missing key, an index out of range, or digging into a scalar" do
      absent = described_class::ABSENT
      expect(described_class.lookup(trace, ["response", "headers", "date"])).to be(absent)
      expect(described_class.lookup(trace, ["sql_writes", 1])).to be(absent)
      expect(described_class.lookup(trace, ["sql_writes", -1])).to be(absent)
      expect(described_class.lookup(trace, ["response", "status", "x"])).to be(absent)
      expect(described_class.lookup(trace, ["sql_writes", "0"])).to be(absent)
    end
  end

  describe "ABSENT" do
    it "inspects as <absent>, so failure messages read well, and is frozen" do
      expect(described_class::ABSENT.inspect).to eq("<absent>")
      expect(described_class::ABSENT.to_s).to eq("<absent>")
      expect(described_class::ABSENT).to be_frozen
    end
  end

  describe ".reproduces?" do
    it "is true when A and A′ give the expected value and B does not" do
      observed = {"control_a" => "x", "control_a_prime" => "x", "candidate_b" => "y"}
      expect(described_class.reproduces?(expected: "x", observed: observed)).to be(true)
    end

    it "is false when B gives the expected value too, or A′ disagrees with A" do
      expect(described_class.reproduces?(expected: "x",
        observed: {"control_a" => "x", "control_a_prime" => "x", "candidate_b" => "x"})).to be(false)
      expect(described_class.reproduces?(expected: "x",
        observed: {"control_a" => "x", "control_a_prime" => "z", "candidate_b" => "y"})).to be(false)
    end

    it "handles ABSENT as an expected value (an added path)" do
      absent = described_class::ABSENT
      expect(described_class.reproduces?(expected: absent,
        observed: {"control_a" => absent, "control_a_prime" => absent, "candidate_b" => "Tue"})).to be(true)
    end

    it "compares Integer and Float strictly, as the diff does (1 is not 1.0)" do
      expect(described_class.reproduces?(expected: 1,
        observed: {"control_a" => 1, "control_a_prime" => 1, "candidate_b" => 1.0})).to be(true)
    end
  end

  describe ".encode_observed" do
    it "wraps values so a missing path can't be confused with any real value" do
      expect(described_class.encode_observed("x")).to eq({"value" => "x"})
      expect(described_class.encode_observed(nil)).to eq({"value" => nil})
      expect(described_class.encode_observed(described_class::ABSENT)).to eq({"absent" => true})
    end
  end

  describe Doubletrack::Repro::Trace do
    it "answers #at(*segments) with the value or ABSENT, and exposes the hash" do
      t = described_class.new(trace)
      expect(t.at("sql_writes", 0, "binds", "name")).to eq("Ada")
      expect(t.at("response", "headers", "date")).to be(Doubletrack::Repro::ABSENT)
      expect(t.to_h).to eq(trace)
    end
  end

  describe Doubletrack::Repro::Result do
    it "is the list of traces of the replayed requests, with #last for the finding's request" do
      r = described_class.new(traces: [{"a" => 1}, {"a" => 2}], rails_version: "8.0.5.1")
      expect(r.size).to eq(2)
      expect(r.last.at("a")).to eq(2)
      expect(r[0].at("a")).to eq(1)
      expect(r.rails_version).to eq("8.0.5.1")
    end
  end
end
