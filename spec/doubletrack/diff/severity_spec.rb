# frozen_string_literal: true

require "doubletrack/diff"

# Exhaustive over channels (ADR 0018). Paths are arrays as produced by Diff::Structural.
RSpec.describe Doubletrack::Diff::Severity do
  def sev(*path) = described_class.classify(path)

  data_changing = [
    ["sql_writes"], ["sql_writes", 0], ["sql_writes", 0, "binds", "total_cents"], ["sql_writes", 0, "statement"],
    ["sql_writes", 0, "table"], ["sql_writes", 0, "sql_literals", 0],
    ["jobs"], ["jobs", 0, "queue_name"], ["jobs", 0, "arguments", 0],
    ["mail"], ["mail", 0, "subject"], ["mail", 0, "html_body"],
    ["cache"], ["cache", 0, "value", "count"], ["cache", 0, "key"],
    ["http"], ["http", 0, "url"], ["http", 0, "request_headers", "accept"],
    ["performed_jobs"], ["performed_jobs", 0, "mail", 0, "subject"], ["performed_jobs", 0, "sql_writes", 0, "binds", "x"],
    ["performed_jobs", 0, "exception"], ["performed_jobs", 0, "queue_name"], ["performed_jobs_truncated"]
  ]
  user_visible = [
    ["response"], ["response", "status"], ["response", "headers", "location"], ["response", "headers", "content-type"],
    ["response", "body"], ["response", "body", "json", "total"], ["response", "body", "html", "children", 0],
    ["response", "set_cookies", "theme", "value"], ["response", "set_cookies", "_s", "attributes", 0],
    ["exception"], ["exception", "class"], ["exception", "message"],
    ["session"], ["session", "recent_order_ids", 0]
  ]
  cosmetic = [
    ["sql_writes", 0, "sql"], ["performed_jobs", 0, "sql_writes", 1, "sql"],
    ["response", "headers", "vary"], ["response", "headers", "cache-control"], ["response", "headers"],
    ["something_new"]
  ]

  data_changing.each { |path| it("#{path.inspect} is data-changing") { expect(sev(*path)).to eq("data-changing") } }
  user_visible.each { |path| it("#{path.inspect} is user-visible") { expect(sev(*path)).to eq("user-visible") } }
  cosmetic.each { |path| it("#{path.inspect} is cosmetic") { expect(sev(*path)).to eq("cosmetic") } }

  it "orders severities" do
    expect(described_class::ORDER).to eq(%w[data-changing user-visible cosmetic])
    expect(described_class.max(%w[cosmetic user-visible])).to eq("user-visible")
    expect(described_class.max([])).to be_nil
  end
end
