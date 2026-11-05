# frozen_string_literal: true

require "json"
require "tmpdir"
require "doubletrack/normalize/trace"

# M1 exit check: traces for known requests contain the expected side effects, on both
# Rails versions. Design: docs/design/recorder.md. Format: docs/formats/trace.md.
RSpec.describe "Recorder traces on fixtures/apps/shop", :integration do
  shop = File.expand_path("../../fixtures/apps/shop", __dir__)

  rates_stub = {
    # Exact match: only the EUR lookup is stubbed; the GBP lookup must be blocked.
    "method" => "GET", "url" => "https://rates.example.test/latest?base=USD&symbols=EUR", "match" => "exact",
    "status" => 200, "headers" => {"content-type" => "application/json"},
    "body" => JSON.generate("rates" => {"EUR" => 0.9})
  }
  session = {
    "id" => "m1-exit-check",
    "http_stubs" => [rates_stub],
    "requests" => [
      {"method" => "POST", "path" => "/orders", "as" => "json",
       "params" => {"email" => "ada@example.com", "name" => "Ada", "total_cents" => 1999}},
      {"method" => "GET", "path" => "/orders"},
      {"method" => "GET", "path" => "/orders/1.json", "params" => {"currency" => "EUR"}},
      {"method" => "GET", "path" => "/orders/1.json", "params" => {"currency" => "GBP"}},
      {"method" => "PATCH", "path" => "/orders/1/cancel", "as" => "json"},
      {"method" => "PATCH", "path" => "/orders/1/audit", "as" => "json"}
    ]
  }

  [%w[control_a Gemfile 8.0.], %w[candidate_b Gemfile.next 8.1.]].each do |role, gemfile, rails|
    context "#{role} (Rails #{rails}x)" do
      before(:all) do
        @work_dir = Dir.mktmpdir("doubletrack-m1-")
        @twin = Doubletrack::Coordinator::TwinProcess.new(
          role: role, app_root: shop, gemfile: File.join(shop, gemfile), work_dir: @work_dir
        )
        @hello = @twin.start
        template = File.join(@work_dir, "template.sqlite3")
        @twin.prepare_snapshot(template_path: template, seed: 0)
        @traces = @twin.run_session(session.merge("snapshot" => template))["traces"]
      end

      after(:all) do
        @twin&.stop
        FileUtils.rm_rf(@work_dir)
      end

      let(:traces) { @traces }

      it "boots the expected Rails version and returns one versioned trace per request" do
        expect(@hello["rails_version"]).to start_with(rails)
        expect(traces.size).to eq(6)
        expect(traces.map { |t| t["trace_version"] }).to all(eq(2))
        expect(traces.map { |t| t.dig("request", "index") }).to eq([0, 1, 2, 3, 4, 5])
      end

      it "POST /orders: insert rows, enqueue the confirmation job, invalidate the cache" do
        t = traces[0]
        expect(t.dig("response", "status")).to eq(201)

        inserts = t["sql_writes"].select { |w| w["statement"] == "INSERT" }
        expect(inserts.map { |w| w["table"] }).to eq(%w[users orders])
        expect(inserts.last["binds"]).to include("total_cents" => 1999, "currency" => "USD", "status" => "pending")
        expect(t["sql_writes"].map { |w| w["statement"] }).to all(match(/\A(INSERT|UPDATE|DELETE|REPLACE)\z/))

        expect(t["jobs"].size).to eq(1)
        expect(t["jobs"].first).to include("job_class" => "OrderConfirmationJob", "queue_name" => "default")
        expect(t["jobs"].first["arguments"]).to eq([{"_aj_globalid" => "gid://shop/Order/1"}])
        expect(t["jobs"].first).not_to include("job_id", "enqueued_at")

        expect(t["cache"]).to eq([{"op" => "delete", "key" => "orders/summary"}])
        expect(t["mail"]).to eq([])
        expect(t["http"]).to eq([])
        expect(t["exception"]).to be_nil
      end

      it "GET /orders: records the cache write with its value and no SQL writes" do
        t = traces[1]
        expect(t.dig("response", "status")).to eq(200)
        expect(t["sql_writes"]).to eq([])
        expect(t["cache"]).to eq([{"op" => "write", "key" => "orders/summary",
                                   "value" => {"count" => 1, "total_cents" => 1999}}])
      end

      it "GET /orders/1?currency=EUR: records the stubbed outbound HTTP call" do
        t = traces[2]
        expect(t.dig("response", "status")).to eq(200)
        expect(t["http"].size).to eq(1)
        call = t["http"].first
        expect(call).to include("method" => "GET", "stubbed" => true)
        expect(call["url"]).to eq("https://rates.example.test/latest?base=USD&symbols=EUR")
        expect(call.dig("response", "status")).to eq(200)
        body = JSON.parse(Doubletrack::Protocol::Message.decode_body(t.dig("response", "body")))
        expect(body["converted"]).to eq("currency" => "EUR", "cents" => 1799)
      end

      it "GET /orders/1?currency=GBP without a stub: blocks the call and records the app's exception" do
        t = traces[3]
        call = t["http"].first
        expect(call).to include("stubbed" => false)
        expect(call.dig("response", "status")).to eq(503)
        expect(call.dig("response", "headers", "x-doubletrack")).to eq(["blocked"])
        expect(t["response"]).to be_nil
        expect(t.dig("exception", "class")).to eq("JSON::ParserError")
      end

      it "PATCH /orders/1/cancel: records the UPDATE and the delivered mail" do
        t = traces[4]
        expect(t.dig("response", "status")).to eq(200)
        update = t["sql_writes"].find { |w| w["statement"] == "UPDATE" }
        expect(update).to include("table" => "orders")
        expect(update["binds"]).to include("status" => "cancelled")

        expect(t["mail"].size).to eq(1)
        mail = t["mail"].first
        expect(mail).to include("mailer" => "OrderMailer", "to" => ["ada@example.com"], "subject" => "Order #1 cancelled")
        expect(mail["text_body"]).to include("has been cancelled")
        expect(mail["html_body"]).to include("<p>Hi Ada,</p>")
      end

      # ADR 0030: an app's own threads act on their own schedule (a push pool finishing
      # an earlier session's work), so their writes are kept apart and never diffed.
      it "PATCH /orders/1/audit: keeps a write from another thread out of the request's side effects" do
        t = traces[5]
        expect(t.dig("response", "status")).to eq(200)
        expect(t["sql_writes"]).to eq([])
        expect(t["background"].size).to eq(1)
        event = t["background"].first
        expect(event).to include("channel" => "sql_writes")
        expect(event["entry"]).to include("statement" => "UPDATE", "table" => "orders")
        expect(Doubletrack::Normalize::Trace.call(t)).not_to have_key("background")
      end
    end
  end
end
