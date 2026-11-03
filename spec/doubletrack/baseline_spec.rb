# frozen_string_literal: true

require "yaml"
require "doubletrack/baseline"

RSpec.describe Doubletrack::Baseline do
  let(:now) { Time.utc(2026, 11, 3, 9, 0, 0) }
  let(:finding) do
    {"id" => "f-bb3068808cf1", "title" => "GET /x: exception.message changed", "severity" => "user-visible",
     "route" => "GET /x", "path" => "exception.message", "op" => "changed"}
  end
  let(:run) { {"run_id" => "20261103T072146Z-42", "twins" => {"control_a" => {"rails_version" => "8.0.5.1"}, "candidate_b" => {"rails_version" => "8.1.4"}}} }

  def write(dir, text)
    path = File.join(dir, "doubletrack.baseline.yml")
    File.write(path, text)
    path
  end

  describe ".load" do
    it "is empty when the file doesn't exist" do
      Dir.mktmpdir do |dir|
        baseline = described_class.load(File.join(dir, "doubletrack.baseline.yml"))
        expect(baseline.entries).to eq([])
        expect(baseline).not_to be_exist
      end
    end

    it "reads accepted entries" do
      Dir.mktmpdir do |dir|
        path = write(dir, <<~YAML)
          baseline_version: 1
          accepted:
          - id: f-bb3068808cf1
            reason: expected
            author: A <a@example.com>
            accepted_at: '2026-11-03T09:00:00Z'
        YAML
        baseline = described_class.load(path)
        expect(baseline.ids).to eq(["f-bb3068808cf1"])
        expect(baseline.entry("f-bb3068808cf1")).to include("reason" => "expected")
      end
    end

    {
      "not a mapping" => "- 1\n",
      "a wrong version" => "baseline_version: 2\naccepted: []\n",
      "an unknown top-level key" => "baseline_version: 1\naccepted: []\nextra: 1\n",
      "an unknown entry key" => "baseline_version: 1\naccepted:\n- {id: f-000000000000, reason: r, author: a, accepted_at: '2026-11-03T09:00:00Z', colour: red}\n",
      "a duplicate id" => "baseline_version: 1\naccepted:\n- {id: f-000000000000, reason: r, author: a, accepted_at: '2026-11-03T09:00:00Z'}\n- {id: f-000000000000, reason: r, author: a, accepted_at: '2026-11-03T09:00:00Z'}\n",
      "a blank reason" => "baseline_version: 1\naccepted:\n- {id: f-000000000000, reason: '  ', author: a, accepted_at: '2026-11-03T09:00:00Z'}\n",
      "a missing author" => "baseline_version: 1\naccepted:\n- {id: f-000000000000, reason: r, accepted_at: '2026-11-03T09:00:00Z'}\n",
      "a malformed id" => "baseline_version: 1\naccepted:\n- {id: bb30, reason: r, author: a, accepted_at: '2026-11-03T09:00:00Z'}\n",
      "invalid YAML" => "baseline_version: [1\n"
    }.each do |label, text|
      it "rejects #{label} with a ConfigError naming the file" do
        Dir.mktmpdir do |dir|
          path = write(dir, text)
          expect { described_class.load(path) }.to raise_error(Doubletrack::ConfigError, /doubletrack\.baseline\.yml/)
        end
      end
    end
  end

  describe "#accept and #write" do
    it "adds an entry with context, keeps entries sorted by id, and writes a commented, loadable file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "doubletrack.baseline.yml")
        baseline = described_class.load(path)
        expect(baseline.accept(finding, reason: "parser text never shown", author: "A <a@example.com>", run: run, now: now)).to eq(:added)
        baseline.accept(finding.merge("id" => "f-000000000001"), reason: "r2", author: "B", run: run, now: now)
        baseline.write

        text = File.read(path)
        expect(text).to start_with("# Doubletrack baseline")
        loaded = described_class.load(path)
        expect(loaded.ids).to eq(%w[f-000000000001 f-bb3068808cf1])
        expect(loaded.entry("f-bb3068808cf1")).to eq(
          "id" => "f-bb3068808cf1", "title" => "GET /x: exception.message changed", "severity" => "user-visible",
          "reason" => "parser text never shown", "author" => "A <a@example.com>",
          "accepted_at" => "2026-11-03T09:00:00Z", "rails" => "8.0.5.1 → 8.1.4", "run_id" => "20261103T072146Z-42"
        )
      end
    end

    it "replaces an existing entry and reports :updated" do
      Dir.mktmpdir do |dir|
        baseline = described_class.load(File.join(dir, "doubletrack.baseline.yml"))
        baseline.accept(finding, reason: "first", author: "A", run: run, now: now)
        expect(baseline.accept(finding, reason: "second", author: "A", run: run, now: now)).to eq(:updated)
        expect(baseline.ids).to eq(["f-bb3068808cf1"])
        expect(baseline.entry("f-bb3068808cf1")["reason"]).to eq("second")
      end
    end

    it "refuses a blank reason or author" do
      Dir.mktmpdir do |dir|
        baseline = described_class.load(File.join(dir, "doubletrack.baseline.yml"))
        expect { baseline.accept(finding, reason: " ", author: "A", run: run, now: now) }.to raise_error(Doubletrack::ConfigError, /reason/)
        expect { baseline.accept(finding, reason: "r", author: "", run: run, now: now) }.to raise_error(Doubletrack::ConfigError, /author/)
      end
    end
  end

  describe "#apply" do
    it "marks accepted findings and lists entries that weren't observed as stale" do
      Dir.mktmpdir do |dir|
        baseline = described_class.load(File.join(dir, "doubletrack.baseline.yml"))
        baseline.accept(finding, reason: "expected", author: "A", run: run, now: now)
        baseline.accept(finding.merge("id" => "f-0000000000aa"), reason: "old", author: "B", run: run, now: now)
        other = finding.merge("id" => "f-0000000000bb")

        findings, stale = baseline.apply([finding, other])
        expect(findings[0]["accepted"]).to eq("reason" => "expected", "author" => "A", "accepted_at" => "2026-11-03T09:00:00Z")
        expect(findings[1]).not_to have_key("accepted")
        expect(stale).to eq(["f-0000000000aa"])
        expect(finding).not_to have_key("accepted") # input not mutated
      end
    end
  end
end
