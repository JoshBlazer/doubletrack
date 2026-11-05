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
    expect(html).to include("Not ready to ship", "50%", "1 of 2 routes", '3</span> <span class="stat-label">noisy differences filtered')
    expect(html).to match(%r{<span class="stat-value">1</span> <span class="stat-label"><span class="badge badge-user-visible"><span class="dot" aria-hidden="true"></span>User-visible</span> finding</span>})
    expect(html).to include("8.0.5", "8.1.4")
  end

  it "renders the finding detail: both sides, timeline, noise evidence, deprecations, accept command" do
    html = page("findings/f-0123456789ab.html")
    expect(html).to include("response.body.json.total", "Control A", "Candidate B", "Session timeline",
      "old thing is deprecated", "doubletrack accept f-0123456789ab")
  end

  # M7 (ADR 0031, 0032): changes group findings across routes, with their likely causes.
  context "with a change seen on two routes and a likely cause" do
    let(:other) do
      finding.merge("id" => "f-ba9876543210", "route" => "PATCH /orders/:id(.:format)", "title" => "PATCH /orders/:id(.:format): response.body.json.total changed")
    end
    let(:change) do
      {"id" => "c-00112233aabb", "severity" => "user-visible", "kind" => "response", "path" => "response.body.json.total", "op" => "changed",
       "summary" => "integer → integer", "delta" => [{"from" => "integer", "to" => "integer"}], "findings" => [finding["id"], other["id"]],
       "routes" => [finding["route"], other["route"]], "sessions" => 2, "occurrences_total" => 2, "accepted" => false,
       "causes" => [{"dependency" => "rails", "evidence" => "commit", "ref" => "e38dd281d3", "text" => "Vary rendered <responses>",
                     "needle" => "X-Requested-With", "url" => "https://github.com/rails/rails/commit/e38dd281d340"}]}
    end

    before do
      run["counts"]["changes"] = 1
      run["dependency_changes"] = [{"name" => "rails", "from" => "8.0.5", "to" => "8.1.4", "from_path" => "/g/a", "to_path" => "/g/b", "git" => nil},
        {"name" => "rack", "from" => "3.2.7", "to" => "3.2.8", "from_path" => "/g/c", "to_path" => "/g/d", "git" => nil}]
      [finding, other].each { |f| f["change_id"] = change["id"] }
      described_class.new(run: run, findings: [finding, other], changes: [change], traces: ->(_s, role) { traces.fetch(role) }).write(@dir)
    end

    it "leads the overview with changes: what changed, on how many routes, and the likely cause" do
      html = page("index.html")
      expect(html).to include("1 change", "JSON response field total changed: integer → integer", "on 2 routes",
        'Likely cause: rails <a href="https://github.com/rails/rails/commit/e38dd281d340"><code>e38dd281d3</code></a> Vary rendered &lt;responses&gt;')
      expect(html).to include("Bundle changes", "<code>rack</code> 3.2.7 → 3.2.8")
    end

    it "lists each change with its findings on the findings page, linked from every finding" do
      expect(page("findings.html")).to include('id="c-00112233aabb"', "findings/f-ba9876543210.html", "(commit, matched “X-Requested-With”)")
      detail = page("findings/f-0123456789ab.html")
      expect(detail).to include('href="../findings.html#c-00112233aabb"', "seen on 2 routes", "Likely causes", "e38dd281d3")
      expect(detail).not_to include("not available until layer L1")
    end
  end

  context "when a change has no likely cause" do
    before do
      change = {"id" => "c-1", "severity" => "user-visible", "kind" => "response", "path" => finding["path"], "op" => "changed",
                "summary" => "adds Total", "delta" => [{"added" => ["Total"], "removed" => []}], "findings" => [finding["id"]], "routes" => [finding["route"]], "sessions" => 1,
                "occurrences_total" => 1, "accepted" => false, "causes" => []}
      finding["change_id"] = "c-1"
      run["dependency_changes"] = [{"name" => "rack", "from" => "3.2.7", "to" => "3.2.8", "from_path" => nil, "to_path" => nil, "git" => nil}]
      described_class.new(run: run, findings: [finding], changes: [change], traces: ->(_s, role) { traces.fetch(role) }).write(@dir)
    end

    it "says none was found among the dependencies that changed, instead of guessing" do
      expect(page("findings/f-0123456789ab.html")).to include("No likely cause found among the 1 dependency that changed")
    end
  end

  # A type change ("1" → 1) must be visible, and JSON null must not read as "absent".
  context "with type changes, nulls and added paths" do
    let(:finding) do
      super().merge("occurrences_total" => 3, "occurrences" => [
        {"session_id" => "s1", "request_index" => 0, "path" => "response.body.json.total", "op" => "changed", "a" => "1", "b" => 1},
        {"session_id" => "s1", "request_index" => 0, "path" => "response.body.json.deleted_at", "op" => "changed", "a" => nil, "b" => "2026"},
        {"session_id" => "s1", "request_index" => 0, "path" => "response.body.json.extra", "op" => "added", "a" => nil, "b" => false}
      ])
    end

    it "quotes strings, shows null as null and (absent) only for the missing side" do
      cells = page("findings/f-0123456789ab.html").scan(%r{<td><pre>(.*?)</pre></td>}m).flatten
      expect(cells).to eq(["&quot;1&quot;", "1", "null", "&quot;2026&quot;", "(absent)", "false"])
    end
  end

  describe "UX of the finding page" do
    let(:html) { page("findings/f-0123456789ab.html") }

    it "states in plain words what changed, under the technical title" do
      expect(html).to include('<p class="lead">JSON response field total changed on <code>POST /orders(.:format)</code>.</p>')
    end

    it "marks the lines that differ in the side-by-side panels, with a non-color cue" do
      expect(html).to match(%r{<del><span class="gutter" aria-hidden="true">−</span>\s*&quot;total&quot;: 1</del>})
      expect(html).to match(%r{<ins><span class="gutter" aria-hidden="true">\+</span>\s*&quot;total&quot;: 2</ins>})
      expect(html).to include("marked − (control A) and + (candidate B)")
    end

    it "names channels the way people say them" do
      expect(html).to include("<summary>SQL writes (same)</summary>", "<summary>Outbound HTTP (same)</summary>",
        "<summary>Performed jobs (same)</summary>")
      expect(html).not_to include("Sql writes", ">Http ")
    end
  end

  context "when a value differs only in whitespace" do
    let(:finding) do
      super().merge("occurrences" => [{"session_id" => "s1", "request_index" => 0, "path" => "sql_writes[0].binds.name",
                                       "op" => "changed", "a" => "Ada  Lovelace", "b" => "Ada Lovelace"}])
    end

    it "says so, since the difference is nearly invisible" do
      expect(page("findings/f-0123456789ab.html")).to include("Differs only in whitespace.")
    end
  end

  context "with a custom baseline and results outside the app" do
    let(:run) do
      super().merge("baseline" => {"path" => "/tmp/custom baseline.yml"}, "results_dir" => "/elsewhere/20261103T000000Z-1")
    end

    it "gives an accept command that targets the same baseline and results" do
      expect(page("findings/f-0123456789ab.html"))
        .to include("doubletrack accept f-0123456789ab --reason &quot;...&quot; --results /elsewhere/20261103T000000Z-1 --baseline /tmp/custom\\ baseline.yml")
    end
  end

  it "puts the finding counts in the verdict, with a link to the findings" do
    html = page("index.html")
    expect(html).to include("1 new finding: 0 data-changing, 1 user-visible, 0 cosmetic.", %(<a class="button" href="findings.html">Review the finding</a>))
    expect(html.index("badge-user-visible")).to be < html.index("route coverage")
  end

  it "lists each finding with a plain description and its reproduction status" do
    html = page("findings.html")
    expect(html).to include("<th scope=\"col\">Reproduction</th>", "JSON response field total", "not generated")
  end

  context "when both sides run Rails from git (an app that tracks Rails main)" do
    let(:run) do
      super().merge("twins" => {
        "control_a" => {"rails_version" => "8.2.0.alpha", "rails_revision" => "1a02651ac37fb64b4de2a2b73461d86acf9c98fb"},
        "control_a_prime" => {"rails_version" => "8.2.0.alpha", "rails_revision" => "1a02651ac37fb64b4de2a2b73461d86acf9c98fb"},
        "candidate_b" => {"rails_version" => "8.2.0.alpha", "rails_revision" => "e3d5c569d217c56c022b04acb127a8c24dbe9685"}
      })
    end

    it "names each side by version and revision" do
      expect(page("index.html")).to include("Rails 8.2.0.alpha (1a02651ac3) → 8.2.0.alpha (e3d5c569d2)")
    end

    # Table headers and eyebrows are uppercased by CSS, which turned the revision into
    # "1A02651AC3" (seen on the once-campfire report): a revision keeps its case.
    it "keeps the revision's case in uppercased headers" do
      expect(page("findings.html")).to include('<span class="rev">1a02651ac3</span>')
      finding = Dir[File.join(@dir, "findings", "*.html")].first
      expect(File.read(finding)).to include('<th scope="col"><span class="side-label side-old" aria-hidden="true">−</span> Control A (Rails 8.2.0.alpha (<span class="rev">1a02651ac3</span>))</th>')
      expect(File.read(File.join(@dir, "style.css"))).to match(/\.rev \{[^}]*text-transform: none/)
    end
  end

  describe "visual encoding" do
    it "gives the severity bar an accessible name with every count and share, and draws no zero parts" do
      html = page("index.html")
      expect(html).to include('role="img" aria-label="New findings by severity: 0 data-changing (0%), 1 user-visible (100%), 0 cosmetic (0%)"')
      expect(html.scan('class="seg seg-').size).to eq(1)
    end

    it "never uses color alone: severity dots and status icons are hidden from assistive tech and sit beside text" do
      html = page("findings.html")
      expect(html).to include('<span class="status status-none"><svg', "not generated</span>")
      expect(html.scan(/<svg[^>]*>/)).to all(include('aria-hidden="true"'))
    end

    it "ships a dark theme and keeps print readable" do
      css = File.read(File.join(@dir, "style.css"))
      expect(css).to include("@media (prefers-color-scheme: dark)", "@media print", "@media (forced-colors: active)")
    end
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
