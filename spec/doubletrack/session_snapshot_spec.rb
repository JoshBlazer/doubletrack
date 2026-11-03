# frozen_string_literal: true

require "json"

# M5 additions to the session format: snapshot kinds and informational test_status.
RSpec.describe Doubletrack::Session do
  def line(overrides = {})
    JSON.generate({"session_version" => 1, "id" => "s1", "requests" => [{"path" => "/orders"}]}.merge(overrides))
  end

  it "defaults to the default snapshot and accepts fixtures (ADR 0026)" do
    expect(described_class.parse(line).snapshot).to eq("default")
    expect(described_class.parse(line("snapshot" => "fixtures")).snapshot).to eq("fixtures")
    expect { described_class.parse(line("snapshot" => "prod")) }.to raise_error(Doubletrack::SessionError, /default.*fixtures/)
  end

  it "keeps test_status out of the replayed requests but exposes it per request" do
    session = described_class.parse(line("requests" => [{"path" => "/a", "test_status" => 201}, {"path" => "/b"},
      {"path" => "/c", "test_status" => "raised"}]))
    expect(session.requests.map(&:keys)).to all(satisfy { |k| !k.include?("test_status") })
    expect(session.test_statuses).to eq([201, nil, "raised"])
  end

  it "rejects a test_status that is not an HTTP status or \"raised\"" do
    expect { described_class.parse(line("requests" => [{"path" => "/a", "test_status" => 42}])) }
      .to raise_error(Doubletrack::SessionError, /test_status/)
    expect { described_class.parse(line("requests" => [{"path" => "/a", "test_status" => "ok"}])) }
      .to raise_error(Doubletrack::SessionError, /test_status/)
  end
end
