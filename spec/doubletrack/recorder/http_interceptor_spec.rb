# frozen_string_literal: true

require "doubletrack/recorder/http_interceptor"

RSpec.describe Doubletrack::Recorder::HttpInterceptor do
  before { described_class.install! }

  let(:stub_rates) do
    {"method" => "GET", "url" => "https://rates.example.test/latest", "match" => "prefix",
     "status" => 200, "headers" => {"Content-Type" => "application/json"}, "body" => '{"ok":true}'}
  end

  it "answers from a matching stub and records the call" do
    sink = []
    body = described_class.recording(stubs: [stub_rates], sink: sink) do
      Net::HTTP.get(URI("https://rates.example.test/latest?base=USD"))
    end
    expect(body).to eq('{"ok":true}')
    expect(sink.size).to eq(1)
    expect(sink.first).to include("method" => "GET", "url" => "https://rates.example.test/latest?base=USD", "stubbed" => true)
    expect(sink.first.dig("response", "headers")).to eq("content-type" => ["application/json"])
  end

  it "blocks unmatched calls with a synthetic 503 and never opens a socket" do
    expect(TCPSocket).not_to receive(:open)
    expect(Socket).not_to receive(:tcp)
    sink = []
    response = described_class.recording(stubs: [stub_rates], sink: sink) do
      Net::HTTP.get_response(URI("http://elsewhere.example.test:8080/x"))
    end
    expect(response.code).to eq("503")
    expect(response["x-doubletrack"]).to eq("blocked")
    expect(response.body).to eq("")
    expect(sink.first).to include("url" => "http://elsewhere.example.test:8080/x", "stubbed" => false)
  end

  it "records POST bodies and matches stubs by method" do
    sink = []
    post_stub = stub_rates.merge("method" => "POST")
    described_class.recording(stubs: [post_stub], sink: sink) do
      Net::HTTP.post(URI("https://rates.example.test/latest"), '{"q":1}', "Content-Type" => "application/json")
      Net::HTTP.get_response(URI("https://rates.example.test/latest"))
    end
    expect(sink.map { |c| [c["method"], c["stubbed"]] }).to eq([["POST", true], ["GET", false]])
    expect(sink.first["request_body"]).to eq('{"q":1}')
  end

  it "requires an exact URL unless match is prefix" do
    exact = stub_rates.merge("match" => "exact")
    expect(described_class.match?(exact, "GET", "https://rates.example.test/latest")).to be(true)
    expect(described_class.match?(exact, "GET", "https://rates.example.test/latest?x=1")).to be(false)
    expect(described_class.match?(stub_rates, "GET", "https://rates.example.test/latest?x=1")).to be(true)
  end

  it "blocks and warns when there is no active recording" do
    expect {
      expect(Net::HTTP.get_response(URI("https://boot.example.test/")).code).to eq("503")
    }.to output(/outbound HTTP outside a replayed request was blocked: GET https:\/\/boot.example.test\//).to_stderr
  end

  it "restores the previous sink after the block, even on error" do
    outer = []
    described_class.recording(stubs: [], sink: outer) do
      expect { described_class.recording(stubs: [], sink: []) { raise "boom" } }.to raise_error("boom")
      Net::HTTP.get_response(URI("https://after.example.test/"))
    end
    expect(outer.map { |c| c["url"] }).to eq(["https://after.example.test/"])
  end
end
