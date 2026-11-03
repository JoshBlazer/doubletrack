# frozen_string_literal: true

require "json"
require "doubletrack/normalize/trace"

RSpec.describe Doubletrack::Normalize::Trace do
  def normalize(trace, **options) = described_class.call(trace, session_cookie: "_shop_session", **options)

  def body(text) = {"encoding" => "utf-8", "data" => text}

  let(:trace) do
    {
      "trace_version" => 2,
      "request" => {"index" => 0, "method" => "GET", "path" => "/orders", "params" => {}, "headers" => {}},
      "route" => {"verb" => "GET", "path" => "/orders(.:format)", "controller" => "orders", "action" => "index"},
      "time" => "2026-01-01T00:00:00.000000Z",
      "response" => {
        "status" => 200,
        "headers" => {
          "content-type" => "text/plain; charset=utf-8",
          "x-request-id" => "6f1c0b0e-2b55-4a39-9b61-1a5a2a3b6c7d",
          "x-runtime" => "0.012345",
          "set-cookie" => "_shop_session=abc--def%3D%3D; path=/; httponly; samesite=lax\ntheme=dark; path=/"
        },
        "body" => body("hello")
      },
      "exception" => nil,
      "session" => {"session_id" => "9f8e", "_csrf_token" => "tok", "recent_order_ids" => [1]},
      "sql_writes" => [], "jobs" => [], "mail" => [], "cache" => [], "http" => [],
      "deprecations" => [{"message" => "x is deprecated", "gem" => "rails"}],
      "performed_jobs" => [],
      "duration_ms" => 12.3
    }
  end

  it "drops volatile response headers and evidence-only fields" do
    out = normalize(trace)
    expect(out["response"]["headers"].keys).to eq(["content-type"])
    expect(out).not_to include("duration_ms", "deprecations")
  end

  it "parses set-cookie into set_cookies and hides only the session cookie's value" do
    out = normalize(trace)
    expect(out["response"]["set_cookies"]).to eq(
      "_shop_session" => {"value" => "<session>", "attributes" => ["httponly", "path=/", "samesite=lax"]},
      "theme" => {"value" => "dark", "attributes" => ["path=/"]}
    )
  end

  it "accepts set-cookie as an array (Rack 3)" do
    trace["response"]["headers"]["set-cookie"] = ["a=1; path=/", "b=2"]
    expect(normalize(trace)["response"]["set_cookies"].keys).to eq(%w[a b])
  end

  it "drops random session keys but keeps the app's session data" do
    expect(normalize(trace)["session"]).to eq("recent_order_ids" => [1])
  end

  it "keeps exception class and message, drops the backtrace, and hides object addresses" do
    trace["response"] = nil
    trace["exception"] = {"class" => "NoMethodError", "message" => "undefined method for #<Order:0x00007f8b1c2d3e40>",
                          "backtrace" => ["/gems/rails-8.0/x.rb:1"]}
    expect(normalize(trace)["exception"]).to eq("class" => "NoMethodError", "message" => "undefined method for #<Order:0x…>")
  end

  it "applies the same rules inside performed jobs" do
    trace["performed_jobs"] = [{"job_class" => "J", "exception" => {"class" => "E", "message" => "m", "backtrace" => ["x"]},
                                "sql_writes" => [], "jobs" => [], "mail" => [], "cache" => [], "http" => []}]
    expect(normalize(trace)["performed_jobs"].first["exception"]).to eq("class" => "E", "message" => "m")
  end

  describe "properties" do
    it "is idempotent and never mutates its input" do
      before = Marshal.load(Marshal.dump(trace))
      once = normalize(trace)
      expect(trace).to eq(before)
      expect(normalize(once)).to eq(once)
    end

    it "is invariant under the volatile fields (request id, runtime, session id, duration, backtrace, cookie value)" do
      random = Random.new(1)
      base = normalize(trace)
      50.times do
        t = Marshal.load(Marshal.dump(trace))
        t["response"]["headers"]["x-request-id"] = random.bytes(8).unpack1("H*")
        t["response"]["headers"]["x-runtime"] = random.rand.to_s
        t["response"]["headers"]["set-cookie"] = "_shop_session=#{random.bytes(12).unpack1("H*")}; path=/; httponly; samesite=lax\ntheme=dark; path=/"
        t["session"]["session_id"] = random.bytes(8).unpack1("H*")
        t["session"]["_csrf_token"] = random.bytes(8).unpack1("H*")
        t["duration_ms"] = random.rand(1000.0)
        expect(normalize(t)).to eq(base)
      end
    end

    it "still distinguishes real changes" do
      changed = Marshal.load(Marshal.dump(trace))
      changed["session"]["recent_order_ids"] = [2]
      expect(normalize(changed)).not_to eq(normalize(trace))
    end
  end
end
