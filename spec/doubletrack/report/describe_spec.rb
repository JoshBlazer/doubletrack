# frozen_string_literal: true

require "doubletrack/report/describe"

RSpec.describe Doubletrack::Report::Describe do
  {
    "response.status" => "HTTP status",
    "response.headers.location" => "response header location",
    "response.body.json.total" => "JSON response field total",
    "response.body.json" => "JSON response body",
    "response.body.html.children[*]" => "HTML response body",
    "response.set_cookies._s.attributes[*]" => "cookie _s",
    "exception.message" => "exception message",
    "sql_writes[*].binds.name" => "SQL write: binds.name",
    "jobs[*].queue_name" => "enqueued job: queue_name",
    "mail[*].text_body" => "email: text_body",
    "cache[*].value.currency" => "cache write: value.currency",
    "http[*].request_headers.accept[*]" => "outbound HTTP call: request_headers.accept",
    "performed_jobs[*].mail[*].subject" => "email: subject, in a job performed after the request",
    "performed_jobs[*].queue_name" => "performed job: queue_name",
    "something_new" => "something_new"
  }.each do |path, text|
    it "describes #{path} as #{text.inspect}" do
      expect(described_class.thing(path)).to eq(text)
    end
  end

  it "says what happened, in which version" do
    expect(described_class.sentence("response.body.json.total", "added", to: "8.1.4"))
      .to eq("JSON response field total appears only on Rails 8.1.4")
    expect(described_class.sentence("response.status", "changed", to: "8.1.4")).to eq("HTTP status changed")
    expect(described_class.sentence("mail[*].subject", "removed", to: "8.1.4")).to eq("email: subject is missing on Rails 8.1.4")
  end
end
