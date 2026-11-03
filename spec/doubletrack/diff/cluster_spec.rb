# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::Cluster do
  def d(index, a, b) = Doubletrack::Diff::Difference.new(path: ["sql_writes", index, "binds", "n"], op: "changed", a: a, b: b)

  it "merges identical fingerprints, counts distinct sessions, and caps evidence at 20 occurrences" do
    cluster = described_class.new
    30.times { |i| cluster.add(session_id: "s#{i % 10}", request_index: i, route_key: "POST /x", difference: d(i % 2, i, i + 1)) }
    findings = cluster.findings
    expect(findings.size).to eq(1)
    f = findings.first
    expect(f).to include("sessions" => 10, "occurrences_total" => 30, "path" => "sql_writes[*].binds.n",
      "kind" => "sql_writes", "severity" => "data-changing", "title" => "POST /x: sql_writes[*].binds.n changed")
    expect(f["occurrences"].size).to eq(20)
    expect(f["occurrences"].first).to include("session_id" => "s0", "request_index" => 0, "path" => "sql_writes[0].binds.n", "a" => 0, "b" => 1)
  end
end
