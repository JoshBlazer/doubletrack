# frozen_string_literal: true

require "json"
require "tmpdir"
require "doubletrack/report"

RSpec.describe Doubletrack::Report::Site do
  def trace(status, total)
    {"trace_version" => 2, "request" => {"index" => 0, "method" => "POST", "path" => "/orders", "params" => {"total" => "<script>x</script>"}, "headers" => {}},
     "route" => {"verb" => "POST", "path" => "/orders(.:format)"}, "time" => "2026-01-01T00:00:00.000000Z",
     "response" => {"status" => status, "headers" => {"content-type" => "application/json"},
                    "body" => {"encoding" => "utf-8", "data" => JSON.generate("total" => total)}},
     "exception" => nil, "session" => {}, "sql_writes" => [], "jobs" => [], "mail" => [], "cache" => [], "http" => [],
     "deprecations" => [{"message" => "old thing is deprecated", "gem" => "Rails"}], "performed_jobs" => [], "duration_ms" => 1}
  end

  let(:finding) do
    {"id" => "f-0123456789ab", "severity" => "user-visible", "kind" => "response", "route" => "POST /orders(.:format)",
     "path" => "response.body.json.total", "op" => "changed", "title" => "POST /orders(.:format): response.body.json.total changed",
     "sessions" => 1, "occurrences_total" => 1,
     "occurrences" => [{"session_id" => "s1", "request_index" => 0, "path" => "response.body.json.total", "a" => 1, "b" => 2}]}
  end

  let(:run) do
    {"run_version" => 1, "run_id" => "20261103T000000Z-1", "seed" => 1, "doubletrack_version" => "0.0.1",
     "app" => {"name" => "Shop", "root" => "/app"}, "started_at" => "2026-11-03T00:00:00Z", "finished_at" => "2026-11-03T00:00:09Z",
     "twins" => {"control_a" => {"rails_version" => "8.0.5"}, "control_a_prime" => {"rails_version" => "8.0.5"}, "candidate_b" => {"rails_version" => "8.1.4"}},
     "sessions" => [{"id" => "s1", "requests" => 1, "findings" => 1}],
     "coverage" => {"routes_total" => 2, "routes_hit" => 1, "ratio" => 0.5,
                    "routes" => [{"verb" => "POST", "path" => "/orders(.:format)", "controller" => "orders", "action" => "create", "hits" => 1},
                      {"verb" => "GET", "path" => "/orders(.:format)", "controller" => "orders", "action" => "index", "hits" => 0}]},
     "noise" => {"a_vs_a_prime_differences" => 3, "a_vs_b_differences" => 4, "suppressed" => 3,
                 "masked_paths" => {"POST /orders(.:format)" => ["response.body.json.token"]}},
     "counts" => {"findings" => 1, "data-changing" => 0, "user-visible" => 1, "cosmetic" => 0}, "verdict" => "not_ready",
     "options" => {"perform_jobs" => true}, "timings" => {}}
  end

  let(:traces) { {"control_a" => [trace(201, 1)], "control_a_prime" => [trace(201, 1)], "candidate_b" => [trace(201, 2)]} }

  around { |ex| Dir.mktmpdir { |dir| @dir = dir and ex.run } }

  before do
    described_class.new(run: run, findings: [finding], traces: ->(session_id, role) { traces.fetch(role) }).write(@dir)
  end

  def page(name) = File.read(File.join(@dir, name))

  it "writes the overview, findings, detail, coverage and noise pages plus local assets" do
    %w[index.html findings.html findings/f-0123456789ab.html coverage.html noise.html style.css enhance.js].each do |f|
      expect(File).to exist(File.join(@dir, f)), f
    end
  end

  it "shows the verdict, severity counts, sessions, noise filtered and coverage on the overview" do
    html = page("index.html")
    expect(html).to include("Not ready to ship", "1 user-visible", "50%", "1 of 2 routes", "3 noisy differences filtered")
    expect(html).to include("8.0.5", "8.1.4")
  end

  it "renders the finding detail: both sides, timeline, noise evidence, deprecations, accept command" do
    html = page("findings/f-0123456789ab.html")
    expect(html).to include("response.body.json.total", "Control A", "Candidate B", "Session timeline",
      "old thing is deprecated", "doubletrack accept f-0123456789ab", "not available until layer L1")
  end

  it "escapes app data" do
    expect(page("findings/f-0123456789ab.html")).not_to include("<script>x</script>")
  end

  it "has no external URLs and works without JS (no inline handlers, one optional script)" do
    Dir.glob(File.join(@dir, "**", "*.{html,css,js}")).each do |file|
      text = File.read(file)
      expect(text).not_to match(%r{(?:src|href)=["']?(?:https?:)?//}i), file
      expect(text).not_to match(/\son[a-z]+=/i), file
      expect(text).not_to match(/@import|url\(\s*["']?https?:/i), file
    end
  end

  it "links only to pages that exist" do
    Dir.glob(File.join(@dir, "**", "*.html")).each do |file|
      File.read(file).scan(/href="([^"#]+)"/).flatten.each do |href|
        expect(File).to exist(File.expand_path(href, File.dirname(file))), "#{file} -> #{href}"
      end
    end
  end

  it "uses semantic, accessible structure" do
    html = page("index.html")
    expect(html).to include('<html lang="en">', "<main", 'class="skip-link"')
    expect(html.scan("<h1").size).to eq(1)
    expect(page("coverage.html")).to include('<th scope="col">')
  end
end
