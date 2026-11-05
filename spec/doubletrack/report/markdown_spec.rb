# frozen_string_literal: true

require "doubletrack/report"

RSpec.describe Doubletrack::Report::Markdown do
  let(:run) do
    {"run_id" => "20261105T211356Z-42", "seed" => 42, "doubletrack_version" => "0.1.0",
     "twins" => {"control_a" => {"rails_version" => "8.0.5.1"}, "candidate_b" => {"rails_version" => "8.1.4"}},
     "sessions" => [{"id" => "a", "requests" => 10}, {"id" => "b", "requests" => 4}],
     "coverage" => {"routes_total" => 8, "routes_hit" => 7, "ratio" => 0.875},
     "noise" => {"suppressed" => 3},
     "counts" => {"findings" => 1, "changes" => 1, "data-changing" => 0, "user-visible" => 1, "cosmetic" => 0, "accepted" => 0},
     "verdict" => "not_ready",
     "dependency_changes" => [{"name" => "json", "from" => nil, "to" => "3.1.0"}, {"name" => "rails", "from" => "8.0.5.1", "to" => "8.1.4"}]}
  end
  let(:finding) { {"id" => "f-bb3068808cf1", "severity" => "user-visible", "route" => "GET /orders/:id(.:format)", "change_id" => "c-8a5d176afec2"} }
  let(:change) do
    {"id" => "c-8a5d176afec2", "severity" => "user-visible", "path" => "exception.message",
     "summary" => %("unexpected token at ''" → "unexpected end of input at line 1 column 1"),
     "findings" => ["f-bb3068808cf1"], "routes" => ["GET /orders/:id(.:format)"], "accepted" => false,
     "causes" => [{"dependency" => "json", "evidence" => "source", "ref" => "ext/json/ext/parser/parser.c", "text" => "appears in 3.1.0", "needle" => "end of input"}]}
  end
  let(:repros) { {"f-bb3068808cf1" => {"repro" => {"status" => "reproduced"}}} }

  def markdown(**overrides)
    described_class.call(run: run, findings: [finding], changes: [change], repros: repros, **overrides)
  end

  it "leads with the marker, the versions and the verdict, then the counts" do
    md = markdown
    expect(md.lines.first.chomp).to eq("<!-- doubletrack-summary -->")
    expect(md).to include("### Doubletrack: Rails 8.0.5.1 → 8.1.4: ❌ Not ready to ship")
    expect(md).to include("**1 new finding in 1 change** (data-changing 0, user-visible 1, cosmetic 0) · 14 requests in 2 sessions · route coverage 7 of 8 (88%) · 3 noisy differences filtered")
  end

  it "lists each change with where it was seen, how many reproduced, and its likely cause" do
    row = markdown.lines.find { |l| l.start_with?("| user-visible") }
    expect(row).to include("`exception.message`", "`GET /orders/:id(.:format)`", "| 1/1 |",
      "json `ext/json/ext/parser/parser.c` (source file)")
    expect(markdown).to include("doubletrack accept c-8a5d176afec2")
  end

  it "escapes table cells and shortens long values" do
    change["summary"] = "a | b\nc #{"x" * 100}"
    row = markdown.lines.find { |l| l.start_with?("| user-visible") }
    expect(row).to include("a \\| b c ")
    expect(row).to include("…")
    expect(row.count("\n")).to eq(1)
  end

  it "says how many routes a wide change touched, and lists the bundle changes folded" do
    change["routes"] = Array.new(22) { |i| "GET /r#{i}" }
    md = markdown
    expect(md).to include("| 22 routes |")
    expect(md).to include("<details><summary>2 bundle changes</summary>", "`json` added at 3.1.0", "`rails` 8.0.5.1 → 8.1.4")
  end

  it "reports a clean run as ready, with accepted changes counted" do
    run.merge!("verdict" => "ready", "counts" => run["counts"].merge("findings" => 0, "changes" => 0, "user-visible" => 0, "accepted" => 1))
    change["accepted"] = true
    md = markdown
    expect(md).to include("✅ Ready to ship", "**No new findings**", "1 accepted in the baseline")
    expect(md).not_to include("| Severity |")
  end

  it "stays under GitHub's comment size limit" do
    many = Array.new(400) { |i| change.merge("id" => "c-#{i}", "summary" => "y" * 200) }
    md = described_class.call(run: run, findings: [], changes: many, repros: {})
    expect(md.length).to be < 60_000
    expect(md).to include("and 375 more changes in the report")
  end
end
