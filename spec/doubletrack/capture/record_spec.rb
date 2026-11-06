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

  # M12 (ADR 0039): a String params is the raw request body.
  it "records a raw string body as body (base64 when it isn't UTF-8), and records xhr and env" do
    record = build(:post, "/x", params: "raw=1", env: {"HTTP_X_API_KEY" => "k"}, xhr: true)
    expect(record).to include("body" => "raw=1", "params" => nil, "env" => {"HTTP_X_API_KEY" => "k"}, "xhr" => true)
    expect(build(:post, "/x", params: "\xFF\x00".b)).to include("body_base64" => ["\xFF\x00".b].pack("m0"))
  end

  it "records an uploaded file from its path, without consuming its IO" do
    require "tempfile"
    Tempfile.create(["moon", ".jpg"]) do |f|
      f.binmode
      f.write("\xFF\xD8jpeg".b)
      f.flush
      upload = Struct.new(:path, :original_filename, :content_type).new(f.path, "moon.jpg", "image/jpeg")
      record = build(:post, "/upload", params: {"attachment" => upload})
      expect(record.dig("params", "attachment")).to eq("$upload" => {"filename" => "moon.jpg", "content_type" => "image/jpeg",
                                                                     "data_base64" => ["\xFF\xD8jpeg".b].pack("m0")})
    end
  end

  it "records an upload backed by a StringIO (no path) without moving its position" do
    require "stringio"
    io = StringIO.new("GIF89a".b)
    upload = Struct.new(:tempfile, :original_filename, :content_type).new(io, "broken.gif", "image/gif")
    record = build(:post, "/upload", params: {"attachment" => upload})
    expect(record.dig("params", "attachment", "$upload", "data_base64")).to eq(["GIF89a"].pack("m0"))
    expect(io.pos).to eq(0)
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
