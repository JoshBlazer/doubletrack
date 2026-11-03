# frozen_string_literal: true

require "json"
require "tmpdir"
require "doubletrack/normalize/trace"

# M2 exit check: the same session replayed twice on the same version produces identical
# normalized traces. Design: docs/design/replay.md.
RSpec.describe "Session replay on fixtures/apps/shop", :integration do
  shop = File.expand_path("../../fixtures/apps/shop", __dir__)

  session_line = {
    "session_version" => 1, "id" => "m2-exit-check", "started_at" => "2026-01-15T09:30:00Z",
    "http_stubs" => [{
      "method" => "GET", "url" => "https://rates.example.test/latest?base=USD&symbols=EUR", "match" => "exact",
      "status" => 200, "headers" => {"content-type" => "application/json"}, "body" => '{"rates":{"EUR":0.9}}'
    }],
    "requests" => [
      {"method" => "POST", "path" => "/orders", "as" => "json", "offset_ms" => 0,
       "params" => {"email" => "ada@example.com", "name" => "Ada", "total_cents" => 1999}},
      {"method" => "POST", "path" => "/orders", "as" => "json", "offset_ms" => 2000,
       "params" => {"email" => "grace@example.com", "name" => "Grace", "total_cents" => 500, "currency" => "EUR"}},
      {"method" => "GET", "path" => "/orders/recent.json", "offset_ms" => 3000},
      {"method" => "GET", "path" => "/orders/1.json", "params" => {"currency" => "EUR"}, "offset_ms" => 4000},
      {"method" => "PATCH", "path" => "/orders/2/cancel", "as" => "json", "offset_ms" => 5000},
      {"method" => "GET", "path" => "/orders", "offset_ms" => 6000}
    ]
  }
  session = Doubletrack::Session.parse(JSON.generate(session_line))

  def json_body(trace) = JSON.parse(Doubletrack::Protocol::Message.decode_body(trace.dig("response", "body")))

  [
    ["control_a", "Gemfile", "8.0.", "control_a_prime"],
    ["candidate_b", "Gemfile.next", "8.1.", nil]
  ].each do |role, gemfile, rails, second_role|
    context "#{role} (Rails #{rails}x)" do
      before(:all) do
        @work_dir = Dir.mktmpdir("doubletrack-m2-")
        @twins = [role, second_role].compact.map do |r|
          Doubletrack::Coordinator::TwinProcess.new(role: r, app_root: shop, gemfile: File.join(shop, gemfile), work_dir: @work_dir)
        end
        @twins.each(&:spawn_process)
        @hello = @twins.map(&:await_hello).first
        template = File.join(@work_dir, "template.sqlite3")
        @snapshot = @twins.first.prepare_snapshot(template_path: template, started_at: session.started_at, seed: 1)
        payload = session.to_payload(run_seed: 1234, snapshot: template)
        @first = @twins.first.run_session(payload)["traces"]
        @second = @twins.first.run_session(payload)["traces"]
        @other = @twins[1]&.run_session(payload)&.fetch("traces")
        cookie = @hello["session_cookie"]
        @normalize = ->(traces) { traces.map { |t| Doubletrack::Normalize::Trace.call(t, session_cookie: cookie) } }
      end

      after(:all) do
        @twins&.each(&:stop)
        FileUtils.rm_rf(@work_dir)
      end

      it "replays the session twice on the same twin with identical normalized traces (exit check)" do
        expect(@first.size).to eq(6)
        expect(@normalize.call(@second)).to eq(@normalize.call(@first))
      end

      if second_role
        it "replays it identically on a second twin process of the same version (exit check)" do
          expect(@normalize.call(@other)).to eq(@normalize.call(@first))
        end
      end

      it "reports routes and the session cookie in hello" do
        expect(@hello["rails_version"]).to start_with(rails)
        expect(@hello["session_cookie"]).to eq("_shop_session")
        expect(@hello["routes"]).to include(
          include("verb" => "PATCH", "path" => "/orders/:id/cancel(.:format)", "controller" => "orders", "action" => "cancel")
        )
      end

      it "builds an empty template from db/schema.rb" do
        expect(@snapshot["tables"]).to include("orders" => 0, "users" => 0)
        expect(@snapshot["sha256"]).to match(/\A\h{64}\z/)
        expect(File.size(@snapshot["template_path"])).to eq(@snapshot["bytes"])
      end

      it "restores the snapshot before every replay, so ids restart at 1" do
        [@first, @second].each { |traces| expect(json_body(traces[0])["id"]).to eq(1) }
      end

      it "freezes time at started_at + offset_ms" do
        expect(@first[0]["time"]).to eq("2026-01-15T09:30:00.000000Z")
        expect(@first[0]["sql_writes"].last["binds"]["created_at"]).to eq("2026-01-15T09:30:00.000000Z")
        expect(@first[1]["sql_writes"].last["binds"]["created_at"]).to eq("2026-01-15T09:30:02.000000Z")
      end

      it "carries the session cookie across requests" do
        expect(@first[2].dig("response", "status")).to eq(200)
        expect(json_body(@first[2])["recent"].map { |o| o["id"] }).to eq([1, 2])
        expect(@first[2]["session"]).to include("recent_order_ids" => [1, 2])
      end

      it "records the route each request hit" do
        expect(@first[4]["route"]).to include("verb" => "PATCH", "path" => "/orders/:id/cancel(.:format)")
      end

      it "performs the enqueued confirmation job inline and records its mail" do
        job = @first[0]["performed_jobs"].first
        expect(job).to include("job_class" => "OrderConfirmationJob", "exception" => nil)
        expect(job["mail"].map { |m| m["subject"] }).to eq(["Order #1 confirmed"])
        expect(@first[0]["mail"]).to eq([]) # request channels stay request-only
      end
    end
  end
end
