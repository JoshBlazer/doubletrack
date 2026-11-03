# frozen_string_literal: true

require "json"
require "doubletrack/capture"

RSpec.describe Doubletrack::Capture::Assembler do
  def rec(test, seq, overrides = {})
    {"test" => test, "location" => "test/integration/orders_test.rb:#{seq}", "pid" => 10, "seq" => seq,
     "method" => "get", "path" => "/orders", "params" => nil, "headers" => {}, "env" => {}, "xhr" => false, "as" => nil,
     "status" => 200}.merge(overrides)
  end

  let(:stubs) { [{"method" => "GET", "url" => "https://rates.example.test/latest", "match" => "prefix", "status" => 200, "body" => "{}"}] }

  def assemble(records, secrets: {}, http_stubs: stubs)
    described_class.new(http_stubs: http_stubs, secrets: secrets).call(records)
  end

  it "groups requests per test, in order, as fixtures-snapshot sessions that Session accepts" do
    result = assemble([
      rec("OrdersTest#test_index", 2, "path" => "/orders.json"),
      rec("OrdersTest#test_create", 3, "method" => "post", "params" => {"total_cents" => 1}, "as" => "json", "status" => 201),
      rec("OrdersTest#test_index", 1)
    ])
    expect(result.sessions.map { |s| s["session"]["id"] }).to eq(%w[OrdersTest-test_create OrdersTest-test_index])
    index = result.sessions.last["session"]
    expect(index).to include("session_version" => 1, "snapshot" => "fixtures", "http_stubs" => stubs)
    expect(index["requests"]).to eq([
      {"method" => "GET", "path" => "/orders", "test_status" => 200},
      {"method" => "GET", "path" => "/orders.json", "test_status" => 200}
    ])
    create = result.sessions.first["session"]["requests"].first
    expect(create).to eq("method" => "POST", "path" => "/orders", "params" => {"total_cents" => 1}, "as" => "json", "test_status" => 201)
    expect(result.sessions.first["comment"]).to include("OrdersTest#test_create", "orders_test.rb:3")
    result.sessions.each { |s| expect { Doubletrack::Session.parse(JSON.generate(s["session"])) }.not_to raise_error }
  end

  it "orders records of one test by pid and sequence, never by arrival" do
    result = assemble([rec("T#a", 2, "path" => "/two"), rec("T#a", 1, "path" => "/one")])
    expect(result.sessions.first["session"]["requests"].map { |r| r["path"] }).to eq(%w[/one /two])
  end

  it "drops scheme and host from full URLs and keeps the query" do
    result = assemble([rec("T#a", 1, "path" => "http://www.example.com/orders/1?currency=EUR")])
    expect(result.sessions.first["session"]["requests"].first["path"]).to eq("/orders/1?currency=EUR")
  end

  it "keeps the query of a URL with no path" do
    result = assemble([rec("T#a", 1, "path" => "http://www.example.com?page=2")])
    expect(result.sessions.first["session"]["requests"].first["path"]).to eq("/?page=2")
  end

  # RSpec examples can share a full description (shared examples, generated names).
  # They are different tests: merging them would replay one on the other's state.
  it "keeps tests with the same name apart when the probe gives distinct test ids" do
    result = assemble([
      rec("Orders works", 1, "test_id" => "./spec/a_spec.rb[1:1]", "path" => "/a"),
      rec("Orders works", 2, "test_id" => "./spec/a_spec.rb[1:2]", "path" => "/b")
    ])
    expect(result.sessions.map { |s| s["session"]["requests"].map { |r| r["path"] } }).to contain_exactly(["/a"], ["/b"])
    expect(result.sessions.map { |s| s["session"]["id"] }.uniq.size).to eq(2)
  end

  it "turns xhr into the headers Rails sets, and HTTP_* env into headers" do
    result = assemble([rec("T#a", 1, "xhr" => true, "env" => {"HTTP_X_API_KEY" => "k", "CONTENT_TYPE" => "text/plain"})])
    headers = result.sessions.first["session"]["requests"].first["headers"]
    expect(headers).to include("X-Requested-With" => "XMLHttpRequest", "X-Api-Key" => "k", "Content-Type" => "text/plain")
    expect(headers["Accept"]).to start_with("text/javascript")
  end

  it "records raised requests as test_status raised" do
    result = assemble([rec("T#a", 1, "status" => nil, "raised" => "ActiveRecord::RecordNotFound")])
    expect(result.sessions.first["session"]["requests"].first["test_status"]).to eq("raised")
  end

  {
    "an unsupported record" => {"unsupported" => "params.file is a Rack::Test::UploadedFile"},
    "a method twins can't replay" => {"method" => "options"},
    "a raw string body" => {"method" => "post", "params" => "a=1"},
    "a non-header env key" => {"env" => {"rack.session" => {}}}
  }.each do |label, overrides|
    it "skips the whole test for #{label}, with a reason" do
      result = assemble([rec("T#bad", 1), rec("T#bad", 2, overrides), rec("T#good", 1)])
      expect(result.sessions.map { |s| s["session"]["id"] }).to eq(["T-good"])
      expect(result.stats["skipped"]).to contain_exactly(include("test" => "T#bad", "reason" => a_string_matching(/\S/)))
    end
  end

  it "writes identical sessions once and counts the duplicates" do
    result = assemble([rec("T#a", 1), rec("T#b", 1), rec("T#c", 1, "path" => "/other")])
    expect(result.sessions.map { |s| s["session"]["id"] }).to eq(%w[T-a T-c])
    expect(result.stats).to include("tests" => 3, "sessions" => 2, "duplicates" => 1, "requests" => 2)
    expect(result.sessions.first["comment"]).to include("also T#b")
  end

  it "makes ids valid and unique, hashing long names" do
    long = "T#" + ("x" * 150)
    result = assemble([rec("A B#c/d", 1), rec("A-B#c d", 1, "path" => "/2"), rec(long, 1, "path" => "/3")])
    ids = result.sessions.map { |s| s["session"]["id"] }
    expect(ids).to all(match(Doubletrack::Session::ID_PATTERN))
    expect(ids.uniq.size).to eq(3)
  end

  it "redacts values of secret-looking environment variables anywhere in a request (ADR 0027)" do
    secrets = described_class.secrets_from("STRIPE_API_KEY" => "sk_live_123456789", "HOME" => "/home/me", "SHORT_TOKEN" => "abc",
      "GITHUB_TOKEN" => "ghp_abcdefghij")
    expect(secrets.keys).to contain_exactly("STRIPE_API_KEY", "GITHUB_TOKEN")
    result = assemble([rec("T#a", 1, "path" => "/hook?key=sk_live_123456789", "headers" => {"Authorization" => "Bearer ghp_abcdefghij"},
      "params" => {"nested" => ["x sk_live_123456789 y"]}, "method" => "post")], secrets: secrets)
    request = result.sessions.first["session"]["requests"].first
    expect(JSON.generate(request)).not_to include("sk_live_123456789", "ghp_abcdefghij")
    expect(request["path"]).to eq("/hook?key=[REDACTED:STRIPE_API_KEY]")
    expect(request["headers"]["Authorization"]).to eq("Bearer [REDACTED:GITHUB_TOKEN]")
    expect(result.stats["redactions"]).to eq(3)
  end

  it "redacts secrets used as parameter or header names too" do
    secrets = described_class.secrets_from("STRIPE_API_KEY" => "sk_live_123456789")
    result = assemble([rec("T#a", 1, "method" => "post", "params" => {"sk_live_123456789" => "1"})], secrets: secrets)
    expect(JSON.generate(result.sessions.first["session"])).not_to include("sk_live_123456789")
  end

  it "renders a sessions file with a header and one comment per session, loadable by Session.load_dir" do
    result = assemble([rec("T#a", 1), rec("T#b", 1, "path" => "/b")])
    text = described_class.to_jsonl(result, header: ["Captured by doubletrack capture"])
    expect(text).to start_with("# Captured by doubletrack capture\n")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "captured.jsonl"), text)
      expect(Doubletrack::Session.load_dir(dir).map(&:id)).to eq(%w[T-a T-b])
    end
  end
end
