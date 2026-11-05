# frozen_string_literal: true

require_relative "../../eval/harness"

RSpec.describe DoubletrackEval::Matcher do
  let(:expected) do
    [{"id" => "P1", "severity" => "data-changing", "findings" => [{"route" => "POST /orders(.:format)", "path" => "sql_writes[*].binds.name"}]},
      {"id" => "P2", "severity" => "user-visible", "findings" => [{"route" => "GET /x", "path" => "response.headers.location"},
        {"route" => "GET /x", "path" => "response.body"}]}]
  end

  def finding(route, path, severity) = {"id" => "f-#{path.hash.abs}", "route" => route, "path" => path, "severity" => severity}

  it "matches by route, path prefix and severity; computes precision and recall" do
    findings = [finding("POST /orders(.:format)", "sql_writes[*].binds.name", "data-changing"),
      finding("GET /x", "response.body.html.children[*]", "user-visible"),
      finding("GET /x", "response.status", "user-visible")]
    out = described_class.new(expected).call(findings)
    expect(out["caught"]).to eq(%w[P1 P2])
    expect(out["missed"]).to eq([])
    expect(out["unexpected"].map { |f| f["path"] }).to eq(["response.status"])
    expect(out["recall"]).to eq(1.0)
    expect(out["precision"]).to be_within(0.001).of(2 / 3.0)
  end

  it "counts a wrong severity as a miss and an unexpected finding" do
    out = described_class.new(expected.first(1)).call([finding("POST /orders(.:format)", "sql_writes[*].binds.name", "cosmetic")])
    expect(out["missed"]).to eq(["P1"])
    expect(out["unexpected"].size).to eq(1)
    expect(out["recall"]).to eq(0.0)
  end

  it "treats zero findings with zero expectations as perfect" do
    out = described_class.new([]).call([])
    expect(out).to include("recall" => 1.0, "precision" => 1.0)
  end

  # M7 (ADR 0031): a change must never mix the findings of two plants.
  it "counts changes and flags any change whose findings no single plant explains" do
    p1 = finding("POST /orders(.:format)", "sql_writes[*].binds.name", "data-changing").merge("change_id" => "c-1")
    p2 = finding("GET /x", "response.headers.location", "user-visible").merge("change_id" => "c-2")
    mixed = finding("GET /x", "response.body", "user-visible").merge("change_id" => "c-1")
    clean = described_class.new(expected).call([p1, p2])
    expect(clean).to include("changes" => 2, "mixed_changes" => [])
    expect(described_class.new(expected).call([p1, p2, mixed])).to include("changes" => 2, "mixed_changes" => ["c-1"])
  end

  it "does not match a path that only shares a textual prefix" do
    out = described_class.new(expected.first(1)).call([finding("POST /orders(.:format)", "sql_writes[*].binds.name_extra", "data-changing")])
    expect(out["missed"]).to eq(["P1"])
  end
end
