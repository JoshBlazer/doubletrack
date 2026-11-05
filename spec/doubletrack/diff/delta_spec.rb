# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::Delta do
  def delta(a, b, path = %w[response headers vary]) = described_class.call(path, a, b)

  # once-campfire PR #423: three different Vary values on control A, one added token.
  it "describes a string change by the tokens it adds and removes, whatever the surrounding value" do
    expected = {"added" => ["X-Requested-With"], "removed" => []}
    expect(delta("Accept, Sec-Fetch-Site", "Accept, X-Requested-With, Sec-Fetch-Site")).to eq(expected)
    expect(delta("Accept, Accept-Encoding, Sec-Fetch-Site", "Accept, X-Requested-With, Accept-Encoding, Sec-Fetch-Site")).to eq(expected)
    expect(delta("Accept", "Accept, X-Requested-With")).to eq(expected)
  end

  it "lists removed tokens, sorted and without duplicates" do
    expect(delta("b a a c", "c")).to eq("added" => [], "removed" => %w[a b])
  end

  it "treats an added or removed string as all-added or all-removed tokens" do
    expect(delta(nil, "max-age=60, public")).to eq("added" => %w[60 max-age public], "removed" => [])
    expect(delta("no-cache", nil)).to eq("added" => [], "removed" => %w[no-cache])
  end

  it "falls back to shapes when the tokens are the same (only order or spacing changed)" do
    expect(delta("a, b", "b,a")).to eq("from" => "string", "to" => "string")
  end

  it "keeps values at enumerated leaves and types elsewhere" do
    expect(delta(200, 500, %w[response status])).to eq("from" => 200, "to" => 500)
    expect(delta(1, 2.0, ["sql_writes", 0, "binds", "total"])).to eq("from" => "integer", "to" => "float")
    expect(delta({"a" => 1}, nil, %w[mail 0])).to eq("from" => "object", "to" => "null")
  end

  it "finds runs of consecutive added words, for searching" do
    runs = described_class.added_runs("unexpected token at ''", "unexpected end of input at line 1 column 1")
    expect(runs).to eq(["end of input", "line 1 column 1"])
  end
end
