# frozen_string_literal: true

require "doubletrack/capture/record"

RSpec.describe Doubletrack::Capture::Record do
  def build(method = :get, path = "/orders", **options) = described_class.build(method: method, path: path, **options)

  it "records the unencoded arguments of Integration::Session#process as JSON-safe data" do
    record = build(:post, "/orders", params: {email: "a@example.com", total_cents: 1999, tags: [:a, "b"], nested: {x: nil, ok: true, f: 1.5}},
      headers: {"X-Trace" => "1"}, as: :json)
    expect(record).to eq(
      "method" => "post", "path" => "/orders",
      "params" => {"email" => "a@example.com", "total_cents" => 1999, "tags" => ["a", "b"], "nested" => {"x" => nil, "ok" => true, "f" => 1.5}},
      "headers" => {"X-Trace" => "1"}, "env" => {}, "xhr" => false, "as" => "json"
    )
  end

  it "accepts nil params and headers and a non-String path" do
    record = build(:get, Struct.new(:to_s).new("/orders/1"), params: nil, headers: nil)
    expect(record).to include("path" => "/orders/1", "params" => nil, "headers" => {})
  end

  it "keeps a raw string body as-is (the assembler decides) and records xhr and env" do
    record = build(:post, "/x", params: "raw=1", env: {"HTTP_X_API_KEY" => "k"}, xhr: true)
    expect(record).to include("params" => "raw=1", "env" => {"HTTP_X_API_KEY" => "k"}, "xhr" => true)
  end

  it "marks params it can't represent as unsupported instead of raising" do
    upload = Object.new
    record = build(:post, "/upload", params: {file: upload})
    expect(record["unsupported"]).to match(/params\.file.*Object/)
  end

  it "marks unknown process options as unsupported" do
    expect(build(:get, "/x", frobnicate: 1)["unsupported"]).to match(/frobnicate/)
  end
end
