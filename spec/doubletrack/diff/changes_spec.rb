# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::Changes do
  def finding(id, route, a, b, path: "response.headers.vary", segments: %w[response headers vary], severity: "cosmetic", op: "changed", sessions: 1, accepted: nil)
    f = {"id" => id, "severity" => severity, "kind" => segments.first, "route" => route, "path" => path, "op" => op,
         "sessions" => sessions, "occurrences_total" => 1,
         "occurrences" => [{"session_id" => "s-#{id}", "request_index" => 0, "segments" => segments, "op" => op, "a" => a, "b" => b}]}
    f["accepted"] = accepted if accepted
    f
  end

  let(:vary) do
    [
      finding("f-1", "GET /a", "Accept, Sec-Fetch-Site", "Accept, X-Requested-With, Sec-Fetch-Site", sessions: 2),
      finding("f-2", "GET /b", "Accept", "Accept, X-Requested-With"),
      finding("f-3", "GET /c", "Accept, Accept-Encoding", "Accept, X-Requested-With, Accept-Encoding")
    ]
  end

  it "groups findings that are the same change on different routes, and tags each finding" do
    findings = vary + [finding("f-4", "GET /a", 200, 500, path: "response.status", segments: %w[response status], severity: "user-visible")]
    changes = described_class.call(findings)

    expect(changes.size).to eq(2)
    status, header = changes
    expect(status).to include("severity" => "user-visible", "findings" => ["f-4"], "summary" => "200 → 500")
    expect(header).to include("severity" => "cosmetic", "kind" => "response", "path" => "response.headers.vary", "op" => "changed",
      "findings" => %w[f-1 f-2 f-3], "routes" => ["GET /a", "GET /b", "GET /c"], "sessions" => 4, "occurrences_total" => 3,
      "summary" => "adds X-Requested-With", "delta" => [{"added" => ["X-Requested-With"], "removed" => []}])
    expect(header["id"]).to match(/\Ac-\h{12}\z/)
    expect(findings.map { |f| f["change_id"] }).to eq([header["id"]] * 3 + [status["id"]])
  end

  it "gives a change the same id in every run, whatever its findings' order" do
    expect(described_class.call(vary.reverse).first["id"]).to eq(described_class.call(vary).first["id"])
  end

  it "keeps different deltas at the same path apart" do
    other = finding("f-9", "GET /d", "Accept", "Accept, Origin")
    expect(described_class.call(vary + [other]).size).to eq(2)
  end

  it "takes the most severe finding's severity and summarizes removals and type changes" do
    changes = described_class.call([
      finding("f-5", "GET /a", "no-cache, private", "private", path: "response.headers.cache-control", segments: %w[response headers cache-control]),
      finding("f-6", "POST /o", 1, nil, path: "sql_writes[*].binds.name", segments: ["sql_writes", 0, "binds", "name"], severity: "data-changing")
    ])
    expect(changes.map { |c| c["summary"] }).to eq(["integer → null", "removes no-cache"])
    expect(changes.first["severity"]).to eq("data-changing")
  end

  it "quotes the values instead of listing many changed tokens" do
    f = finding("f-7", "GET /o", "unexpected token at ''", "unexpected end of input at line 1 column 1", path: "exception.message", segments: %w[exception message], severity: "user-visible")
    expect(described_class.call([f]).first["summary"]).to eq(%("unexpected token at ''" → "unexpected end of input at line 1 column 1"))
  end

  it "marks a change accepted only when all its findings are" do
    accepted = {"reason" => "ok"}
    some = described_class.call([finding("f-1", "GET /a", "A", "A, B", accepted: accepted), finding("f-2", "GET /b", "A", "A, B")])
    all = described_class.call([finding("f-1", "GET /a", "A", "A, B", accepted: accepted), finding("f-2", "GET /b", "A", "A, B", accepted: accepted)])
    expect(some.first["accepted"]).to be(false)
    expect(all.first["accepted"]).to be(true)
  end
end
