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

  # Found on shop: one changed HTML page produced 23 findings from index-shifted tree paths.
  it "collapses every difference inside an HTML body into one finding per route, keeping concrete paths" do
    cluster = described_class.new
    paths = [%w[children], [0, "children", 1, "attrs", "class"], [0, "children", 4], [0, "children", 7, "children", 0]]
    paths.each_with_index do |rest, i|
      op = i.even? ? "changed" : "added"
      diff = Doubletrack::Diff::Difference.new(path: ["response", "body", "html", *rest], op: op, a: "x", b: "y")
      cluster.add(session_id: "s1", request_index: 0, route_key: "GET /x", difference: diff)
    end
    findings = cluster.findings
    expect(findings.size).to eq(1)
    expect(findings.first).to include("path" => "response.body.html", "op" => "changed", "occurrences_total" => 4,
      "severity" => "user-visible", "title" => "GET /x: response.body.html changed")
    expect(findings.first["occurrences"].map { |o| o["path"] }).to include("response.body.html[0].children[1].attrs.class")
  end
end
