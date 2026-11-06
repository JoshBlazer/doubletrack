# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# M5 exit check: `doubletrack capture` on shop produces sessions from its request tests,
# and `run` uses them, with every replayed request getting the status its test saw.
RSpec.describe "doubletrack capture on fixtures/apps/shop", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  def cli(root, *args)
    Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), *args, chdir: root)
  end

  def tracked_changes(root, dir)
    out, = Open3.capture2("git", "-C", root, "status", "--porcelain", "--", dir)
    out
  end

  before(:all) do
    @tmp = Dir.mktmpdir("doubletrack-m5-")
    @sessions_file = File.join(@tmp, "sessions", "captured.jsonl")
    @before = tracked_changes(root, shop)
    @cap_out, @cap_err, @cap_status = cli(root, "capture", shop, "--out", @sessions_file)
    @sessions = File.exist?(@sessions_file) ? Doubletrack::Session.load_dir(File.dirname(@sessions_file)) : []
    @run_out, @run_err, @run_status = cli(root, "run", shop, "--sessions", File.dirname(@sessions_file), "--out",
      File.join(@tmp, "runs"), "--seed", "5", "--baseline", File.join(@tmp, "baseline.yml"))
    @results = Dir.glob(File.join(@tmp, "runs", "*")).find { |d| File.directory?(d) }
    @run = @results ? JSON.parse(File.read(File.join(@results, "run.json"))) : {}
  end

  after(:all) { FileUtils.rm_rf(@tmp) }

  it "exits 0, runs the app's tests, and summarizes what it captured" do
    expect(@cap_status.exitstatus).to eq(0), "#{@cap_out}\n#{@cap_err}"
    expect(@cap_out).to include("Captured", "sessions", "captured.jsonl")
    expect(@cap_out).to match(/tests: passed/)
  end

  it "turns each request-making integration test into a fixtures-snapshot session" do
    ids = @sessions.map(&:id)
    expect(ids).to include(a_string_starting_with("OrdersFlowTest-test_creating_an_order"),
      a_string_starting_with("OrdersFlowTest-test_cancelling"), a_string_starting_with("OrdersFlowTest-test_fixture"))
    expect(@sessions.map(&:snapshot).uniq).to eq(["fixtures"])
    expect(@sessions.map(&:http_stubs)).to all(include(include("url" => a_string_starting_with("https://rates.example.test/"))))
  end

  it "keeps each test's requests in order with their unencoded params and as: option" do
    recent = @sessions.find { |s| s.id.start_with?("OrdersFlowTest-test_recent") }
    expect(recent.requests.map { |r| [r["method"], r["path"]] }).to eq([["POST", "/orders"], ["POST", "/orders"], ["GET", "/orders/recent.json"]])
    expect(recent.requests.first).to include("as" => "json", "params" => include("email" => "ada@example.com", "total_cents" => 1000))
    expect(recent.test_statuses).to eq([201, 201, 200])
  end

  it "leaves the app's tracked files untouched" do
    expect(tracked_changes(root, shop)).to eq(@before)
  end

  # M12 (ADR 0039): raw bodies, uploads and hosts are captured instead of skipped.
  it "captures a raw body, an upload and the request host" do
    by_test = ->(name) { @sessions.find { |s| s.id.start_with?("CaptureCasesTest-test_#{name}") } }
    webhook = by_test.call("the_payments_webhook")
    expect(webhook).not_to be_nil, @sessions.map(&:id).inspect
    expect(webhook.requests.first).to include("method" => "POST", "path" => "/webhooks/payments", "body" => '{"event":"payment.succeeded"}')
    upload = by_test.call("a_receipt_can_be_uploaded").requests.first
    expect(upload.dig("params", "receipt", "$upload")).to include("filename" => "receipt.txt", "content_type" => "text/plain")
    # host! and a full URL give the same request, so capture writes that session once
    # (duplicates are listed in its comment).
    admin = by_test.call("a_full_URL") || by_test.call("admin_stats")
    expect(admin.requests.first).to include("host" => "admin.example.com", "path" => "/admin/stats")
  end

  it "runs the captured sessions on A, A′ and B (exit 0 or 1, never 2)" do
    expect([0, 1]).to include(@run_status.exitstatus), "#{@run_out}\n#{@run_err}"
    expect(@run["sessions"].map { |s| s["id"] }).to match_array(@sessions.map(&:id))
    expect(@run["snapshots"].keys).to eq(["fixtures"])
    expect(@run.dig("snapshots", "fixtures", "tables")).to include("orders" => be > 0, "users" => be > 0)
  end

  it "replays every captured request with the status its test saw (capture fidelity, ADR 0027)" do
    fidelity = @run["capture_fidelity"]
    expect(fidelity["requests"]).to eq(@sessions.sum { |s| s.test_statuses.compact.size })
    expect(fidelity["mismatches"]).to eq([]), JSON.pretty_generate(fidelity)
    expect(fidelity["matched"]).to eq(fidelity["requests"])
    expect(@run_out).to match(%r{Capture fidelity: (\d+)/\1 requests})
  end

  it "resolves fixture ids: the fixture test's request found its record on every twin" do
    session = @sessions.find { |s| s.id.start_with?("OrdersFlowTest-test_fixture") }
    %w[control_a control_a_prime candidate_b].each do |role|
      trace = JSON.parse(File.read(File.join(@results, "traces", session.id, "#{role}.json"))).first
      expect(trace.dig("response", "status")).to eq(200), role
      expect(JSON.parse(trace.dig("response", "body", "data"))).to include("status" => "paid")
    end
  end

  it "captures the same sessions when the tests run on the next Rails (the probe works on both)" do
    next_file = File.join(@tmp, "next", "captured.jsonl")
    out, err, status = cli(root, "capture", shop, "--out", next_file, "--gemfile", File.join(shop, "Gemfile.next"))
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    strip = ->(path) { File.readlines(path).grep(/\A\{/) }
    expect(strip.call(next_file)).to eq(strip.call(@sessions_file))
  end
end
