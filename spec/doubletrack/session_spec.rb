# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Doubletrack::Session do
  def line(overrides = {})
    JSON.generate({"session_version" => 1, "id" => "s1", "requests" => [{"path" => "/orders"}]}.merge(overrides))
  end

  describe ".parse" do
    it "fills defaults: method, params, headers, offset_ms, started_at" do
      session = described_class.parse(line("requests" => [{"path" => "/a"}, {"path" => "/b", "method" => "post"}]))
      expect(session.id).to eq("s1")
      expect(session.started_at).to eq("2026-01-01T00:00:00Z")
      expect(session.requests).to eq([
        {"method" => "GET", "path" => "/a", "params" => {}, "headers" => {}, "offset_ms" => 0},
        {"method" => "POST", "path" => "/b", "params" => {}, "headers" => {}, "offset_ms" => 1000}
      ])
      expect(session.http_stubs).to eq([])
    end

    it "keeps explicit offsets and the as option" do
      session = described_class.parse(line("requests" => [{"path" => "/a", "offset_ms" => 5, "as" => "json"}]))
      expect(session.requests.first).to include("offset_ms" => 5, "as" => "json")
    end

    {
      "unknown keys" => [{"extra" => 1}, /unknown key "extra"/],
      "a missing id" => [{"id" => nil}, /id/],
      "an unsafe id" => [{"id" => "../x"}, /id/],
      "no requests" => [{"requests" => []}, /at least one request/],
      "a bad method" => [{"requests" => [{"path" => "/", "method" => "TRACE"}]}, /method/],
      "a relative path" => [{"requests" => [{"path" => "orders"}]}, /path/],
      "decreasing offsets" => [{"requests" => [{"path" => "/", "offset_ms" => 10}, {"path" => "/", "offset_ms" => 5}]}, /offset_ms/],
      "a newer version" => [{"session_version" => 2}, /session_version/],
      "a bad started_at" => [{"started_at" => "yesterday"}, /started_at/],
      "unknown request keys" => [{"requests" => [{"path" => "/", "bodyy" => "x"}]}, /unknown key "bodyy"/],
      "both body and body_base64" => [{"requests" => [{"path" => "/", "body" => "x", "body_base64" => "eA=="}]}, /both body and body_base64/],
      "a non-boolean https" => [{"requests" => [{"path" => "/", "https" => "yes"}]}, /https must be true or false/]
    }.each do |what, (overrides, message)|
      it "rejects #{what}" do
        expect { described_class.parse(line(overrides), source: "x.jsonl:3") }
          .to raise_error(Doubletrack::SessionError, /x\.jsonl:3: .*#{message}/)
      end
    end

    it "rejects invalid JSON with its source" do
      expect { described_class.parse("{nope", source: "x.jsonl:1") }.to raise_error(Doubletrack::SessionError, /x\.jsonl:1/)
    end
  end

  describe ".load_dir" do
    it "reads *.jsonl in sorted order, skipping blank and comment lines, and rejects duplicate ids" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "b.jsonl"), "#{line("id" => "b1")}\n")
        File.write(File.join(dir, "a.jsonl"), "# comment\n\n#{line("id" => "a1")}\n#{line("id" => "a2")}\n")
        File.write(File.join(dir, "ignored.txt"), "junk")
        expect(described_class.load_dir(dir).map(&:id)).to eq(%w[a1 a2 b1])

        File.write(File.join(dir, "c.jsonl"), "#{line("id" => "a1")}\n")
        expect { described_class.load_dir(dir) }.to raise_error(Doubletrack::SessionError, /c\.jsonl:1: duplicate session id "a1"/)
      end
    end

    it "fails clearly when the directory has no sessions" do
      Dir.mktmpdir do |dir|
        expect { described_class.load_dir(dir) }.to raise_error(Doubletrack::SessionError, /no sessions/)
      end
    end
  end

  describe ".seed_for" do
    it "is stable, depends on run seed and id, and not on order" do
      expect(described_class.seed_for(42, "a")).to eq(described_class.seed_for(42, "a"))
      expect(described_class.seed_for(42, "a")).not_to eq(described_class.seed_for(43, "a"))
      expect(described_class.seed_for(42, "a")).not_to eq(described_class.seed_for(42, "b"))
      expect(described_class.seed_for(42, "a")).to be_between(0, 2**64 - 1)
    end
  end

  it "builds the protocol payload" do
    session = described_class.parse(line)
    payload = session.to_payload(run_seed: 7, snapshot: "/tmp/t.sqlite3")
    expect(payload).to include("id" => "s1", "snapshot" => "/tmp/t.sqlite3", "started_at" => "2026-01-01T00:00:00Z",
      "seed" => described_class.seed_for(7, "s1"), "http_stubs" => [])
    expect(payload["requests"].first["path"]).to eq("/orders")
  end

  # M12 (ADR 0039)
  it "keeps a raw body, the host and https on a request" do
    session = described_class.parse(JSON.generate("session_version" => 1, "id" => "s",
      "requests" => [{"method" => "POST", "path" => "/hook", "body" => "{}", "host" => "admin.example.com", "https" => true}]), source: "x")
    expect(session.requests.first).to include("body" => "{}", "host" => "admin.example.com", "https" => true)
  end
end
