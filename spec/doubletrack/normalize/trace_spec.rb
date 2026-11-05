# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
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

  describe "M3 rules (docs/design/diff.md#normalization)" do
    it "drops route, time, request, etag and content-length (evidence or derived from the body, never compared)" do
      trace["response"]["headers"]["etag"] = 'W/"abc"'
      trace["response"]["headers"]["content-length"] = "5"
      out = normalize(trace)
      expect(out).not_to include("route", "time", "request")
      expect(out["response"]["headers"]).not_to include("etag", "content-length")
    end

    it "normalizes bodies by content type" do
      trace["response"]["headers"]["content-type"] = "application/json; charset=utf-8"
      trace["response"]["body"] = body('{"b":1,"a":2}')
      expect(normalize(trace)["response"]["body"]).to eq("json" => {"a" => 2, "b" => 1})

      trace["response"]["headers"]["content-type"] = "text/html; charset=utf-8"
      trace["response"]["body"] = body("<p  class='x'>hi</p>")
      expect(normalize(trace)["response"]["body"]).to have_key("html")

      trace["response"]["headers"]["content-type"] = "text/plain"
      trace["response"]["body"] = body("hello")
      expect(normalize(trace)["response"]["body"]).to eq("text" => "hello")

      trace["response"]["body"] = {"encoding" => "base64", "data" => ["\xFF\x00".b].pack("m0")}
      expect(normalize(trace)["response"]["body"]).to eq("sha256" => Digest::SHA256.hexdigest("\xFF\x00".b))
    end

    # once-campfire gzips cached pages with Zlib.gzip, whose header carries the C-level
    # time(), which Doubletrack's frozen clock doesn't reach: the bytes of the same page
    # differ by the second the request ran in. Compare the decoded content instead.
    it "compares a gzip-encoded body by its decoded content, whatever the gzip header time" do
      require "zlib"
      html = "<p class='x'>hi</p>"
      trace["response"]["headers"]["content-type"] = "text/html; charset=utf-8"
      trace["response"]["headers"]["content-encoding"] = "gzip"
      bodies = [1, 2].map do |mtime|
        io = StringIO.new("".b)
        gz = Zlib::GzipWriter.new(io)
        gz.mtime = mtime
        gz.write(html)
        gz.close
        trace["response"]["body"] = {"encoding" => "base64", "data" => [io.string].pack("m0")}
        normalize(trace)["response"]["body"]
      end
      expect(bodies.uniq.size).to eq(1)
      expect(bodies.first).to have_key("html")
      expect(normalize(trace)["response"]["headers"]).to include("content-encoding" => "gzip")
    end

    it "keeps the sha256 of a body that claims gzip but doesn't decode" do
      trace["response"]["headers"]["content-encoding"] = "gzip"
      trace["response"]["body"] = {"encoding" => "base64", "data" => ["\xFF\x00".b].pack("m0")}
      expect(normalize(trace)["response"]["body"]).to eq("sha256" => Digest::SHA256.hexdigest("\xFF\x00".b))
    end

    it "falls back to text when a JSON body does not parse" do
      trace["response"]["headers"]["content-type"] = "application/json"
      trace["response"]["body"] = body("{oops")
      expect(normalize(trace)["response"]["body"]).to eq("text" => "{oops")
    end

    it "canonicalizes SQL, moves literals out, drops the statement name and ignored columns" do
      trace["sql_writes"] = [{"statement" => "INSERT", "table" => "orders", "name" => "Order Create",
                              "sql" => %(INSERT INTO "orders" ("a", "updated_at") VALUES (?, ?)),
                              "binds" => {"a" => 1, "updated_at" => "2026-01-01T00:00:00.000000Z"}}]
      write = normalize(trace, ignored_columns: ["updated_at"])["sql_writes"].first
      expect(write).to eq("statement" => "INSERT", "table" => "orders", "sql" => "INSERT INTO orders (a, updated_at) VALUES (?, ?)",
        "sql_literals" => [], "binds" => {"a" => 1})
    end

    it "normalizes mail HTML bodies and trailing whitespace in text bodies, in jobs too" do
      mail = {"mailer" => "M", "subject" => "s", "text_body" => "Hi  \nthere \n", "html_body" => "<p>Hi   <b>x</b></p>\n"}
      trace["mail"] = [mail]
      trace["performed_jobs"] = [{"job_class" => "J", "exception" => nil, "mail" => [mail],
                                  "sql_writes" => [], "jobs" => [], "cache" => [], "http" => []}]
      out = normalize(trace)
      expect(out["mail"].first["text_body"]).to eq("Hi\nthere\n")
      expect(out["mail"].first["html_body"]).to eq(Doubletrack::Normalize::Html.canonical("<p>Hi <b>x</b></p>"))
      expect(out["performed_jobs"].first["mail"]).to eq(out["mail"])
    end
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
