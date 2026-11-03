# frozen_string_literal: true

require "doubletrack/diff"

# Hand-built traces through the whole analysis: normalize, mask, fingerprint, cluster,
# severity, coverage (docs/design/diff.md).
RSpec.describe Doubletrack::Diff::Analyzer do
  def trace(index:, route:, status: 200, body: {"id" => 1}, token: "t", sql: [], mail: [], request_id: "r")
    {
      "trace_version" => 2,
      "request" => {"index" => index, "method" => route.split.first, "path" => "/x", "params" => {}, "headers" => {}},
      "route" => {"verb" => route.split.first, "path" => route.split.last, "controller" => "orders", "action" => "x"},
      "time" => "2026-01-01T00:00:00.000000Z",
      "response" => {"status" => status, "headers" => {"content-type" => "application/json", "x-request-id" => request_id},
                     "body" => {"encoding" => "utf-8", "data" => JSON.generate(body.merge("token" => token))}},
      "exception" => nil, "session" => {},
      "sql_writes" => sql, "jobs" => [], "mail" => mail, "cache" => [], "http" => [],
      "deprecations" => [], "performed_jobs" => [], "duration_ms" => 1.0
    }
  end

  def insert(total) = [{"statement" => "INSERT", "table" => "orders", "name" => "Order Create",
                        "sql" => "INSERT INTO orders (total) VALUES (?)", "binds" => {"total" => total}}]

  let(:routes) do
    [{"verb" => "POST", "path" => "/orders(.:format)", "controller" => "orders", "action" => "create"},
      {"verb" => "GET", "path" => "/orders(.:format)", "controller" => "orders", "action" => "index"},
      {"verb" => "DELETE", "path" => "/orders/:id(.:format)", "controller" => "orders", "action" => "destroy"}]
  end

  # Two sessions; B rounds totals differently (data-changing, both sessions) and session s2's
  # GET changes status (user-visible). Tokens and request ids are random everywhere (noise).
  let(:sessions) do
    %w[s1 s2].map do |sid|
      a, ap, b = [1, 2, 3].map do |n|
        total = (n == 3) ? 1000 : 1001
        status = (n == 3 && sid == "s2") ? 500 : 200
        [trace(index: 0, route: "POST /orders(.:format)", sql: insert(total), token: "#{sid}#{n}", request_id: rand.to_s),
          trace(index: 1, route: "GET /orders(.:format)", status: status, token: "#{sid}#{n}x", request_id: rand.to_s)]
      end
      {"id" => sid, "traces" => {"control_a" => a, "control_a_prime" => ap, "candidate_b" => b}}
    end
  end

  let(:result) { described_class.new(routes: routes, session_cookie: nil).call(sessions) }

  it "clusters the same cause across sessions into one finding with a count" do
    sql = result[:findings].find { |f| f["kind"] == "sql_writes" }
    expect(sql).to include("severity" => "data-changing", "route" => "POST /orders(.:format)",
      "path" => "sql_writes[*].binds.total", "op" => "changed", "sessions" => 2, "occurrences_total" => 2)
    expect(sql["occurrences"].first).to include("session_id" => "s1", "request_index" => 0, "a" => 1001, "b" => 1000)
  end

  it "reports the status change as user-visible, only where it happened" do
    status = result[:findings].find { |f| f["path"] == "response.status" }
    expect(status).to include("severity" => "user-visible", "sessions" => 1, "route" => "GET /orders(.:format)")
  end

  it "masks noise seen between A and A' and counts it" do
    expect(result[:findings].map { |f| f["path"] }).not_to include("response.body.json.token")
    expect(result[:noise]["masked_paths"]["POST /orders(.:format)"]).to eq(["response.body.json.token"])
    expect(result[:noise]["suppressed"]).to be >= 4
    expect(result[:noise]["a_vs_a_prime_differences"]).to eq(4)
  end

  it "sorts findings by severity, then route, then path" do
    expect(result[:findings].map { |f| f["severity"] }).to eq(%w[data-changing user-visible])
  end

  it "computes route coverage" do
    expect(result[:coverage]).to include("routes_total" => 3, "routes_hit" => 2)
    expect(result[:coverage]["ratio"]).to be_within(0.001).of(2 / 3.0)
    expect(result[:coverage]["routes"].find { |r| r["action"] == "destroy" }["hits"]).to eq(0)
  end

  it "treats a session with no traces as empty, not a crash" do
    result = described_class.new(routes: routes, session_cookie: nil).call([{"id" => "s0", "traces" => {}}])
    expect(result[:findings]).to eq([])
  end

  it "finds nothing when B behaves like A" do
    same = sessions.map { |s| s.merge("traces" => s["traces"].merge("candidate_b" => s["traces"]["control_a"])) }
    expect(described_class.new(routes: routes, session_cookie: nil).call(same)[:findings]).to eq([])
  end

  it "fails clearly when twins returned different numbers of traces" do
    broken = [sessions.first.merge("traces" => sessions.first["traces"].merge("candidate_b" => []))]
    expect { described_class.new(routes: routes, session_cookie: nil).call(broken) }.to raise_error(Doubletrack::Error, /s1/)
  end
end
