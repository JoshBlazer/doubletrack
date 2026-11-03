# frozen_string_literal: true

require "doubletrack/diff"

RSpec.describe Doubletrack::Diff::Fingerprint do
  def d(path, a, b, op = "changed") = Doubletrack::Diff::Difference.new(path: path, op: op, a: a, b: b)
  def fp(diff, route = "POST /orders(.:format)") = described_class.call(route_key: route, difference: diff)

  it "looks like f- plus 12 hex characters" do
    expect(fp(d(["response", "status"], 200, 500))).to match(/\Af-\h{12}\z/)
  end

  it "ignores values at ordinary leaves, so one cause across sessions is one finding" do
    expect(fp(d(["sql_writes", 0, "binds", "total_cents"], 1999, 2000)))
      .to eq(fp(d(["sql_writes", 3, "binds", "total_cents"], 500, 501)))
  end

  it "keeps values at enumerated leaves" do
    expect(fp(d(["response", "status"], 200, 500))).not_to eq(fp(d(["response", "status"], 200, 404)))
    expect(fp(d(["jobs", 0, "queue_name"], "default", "mailers"))).not_to eq(fp(d(["jobs", 0, "queue_name"], "default", "low")))
    expect(fp(d(["exception", "class"], "A", "B"))).not_to eq(fp(d(["exception", "class"], "A", "C")))
    expect(fp(d(["response", "headers", "content-type"], "text/html", "application/json")))
      .not_to eq(fp(d(["response", "headers", "content-type"], "text/html", "text/plain")))
  end

  it "depends on route, op, and value types" do
    base = d(["response", "body", "json", "total"], 1, 2)
    expect(fp(base)).not_to eq(fp(base, "GET /orders(.:format)"))
    expect(fp(base)).not_to eq(fp(d(["response", "body", "json", "total"], nil, 2, "added")))
    expect(fp(base)).not_to eq(fp(d(["response", "body", "json", "total"], 1, "2")))
  end

  it "names the channel (kind)" do
    expect(described_class.kind(["sql_writes", 0, "binds", "x"])).to eq("sql_writes")
    expect(described_class.kind(["performed_jobs", 0, "mail", 0, "subject"])).to eq("performed_jobs.mail")
    expect(described_class.kind(["performed_jobs", 0, "queue_name"])).to eq("performed_jobs")
    expect(described_class.kind(["response", "status"])).to eq("response")
  end
end
