# frozen_string_literal: true

require "stringio"
require "doubletrack/cli"
require_relative "../support/results_fixture"

RSpec.describe Doubletrack::CLI do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    code = described_class.start(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  it "prints usage with exit 0" do
    code, out, = run_cli("help")
    expect(code).to eq(0)
    expect(out).to include("Upgrade Rails with proof, not hope.", "run", "accept")
  end

  it "prints the version" do
    expect(run_cli("version")[1]).to eq("doubletrack #{Doubletrack::VERSION}\n")
  end

  it "refuses unimplemented commands with exit 2 and names the milestone" do
    code, _, err = run_cli("bisect", "f-123")
    expect(code).to eq(2)
    expect(err).to include("not implemented yet", "L1")
  end

  it "run: exits 2 with a clear message when the app is not dual-booted" do
    Dir.mktmpdir do |dir|
      code, _, err = run_cli("run", dir)
      expect(code).to eq(2)
      expect(err).to include("Gemfile not found", "ADR 0001")
    end
  end

  it "run: rejects unknown doubletrack.yml keys and bad options with exit 2" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "doubletrack.yml"), "perfom_jobs: false\n")
      code, _, err = run_cli("run", dir)
      expect(code).to eq(2)
      expect(err).to include('unknown doubletrack.yml key "perfom_jobs"')
    end
    expect(run_cli("run", "--seed", "abc").first).to eq(2)
  end

  it "report: exits 2 when the directory is not a results directory" do
    Dir.mktmpdir do |dir|
      code, _, err = run_cli("report", dir)
      expect(code).to eq(2)
      expect(err).to include("run.json not found")
    end
  end

  it "rejects unknown commands with exit 2" do
    expect(run_cli("frobnicate").first).to eq(2)
  end

  describe "accept" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @app = File.join(dir, "app")
        @results = File.join(@app, "tmp", "doubletrack", "20261103T000000Z-1")
        ResultsFixture.build(@results, app_root: @app)
        require "doubletrack/results"
        @finding = Doubletrack::Results.analyze(@results, JSON.parse(File.read(File.join(@results, "run.json"))))[1].first
        ex.run
      end
    end

    let(:baseline) { File.join(@app, "doubletrack.baseline.yml") }

    it "writes the finding to doubletrack.baseline.yml in the app, from the newest results" do
      code, out, err = run_cli("accept", @finding["id"], "--reason", "intended", "--author", "A <a@example.com>", @app)
      expect(code).to eq(0), err
      expect(out).to include("Accepted #{@finding["id"]}", "doubletrack.baseline.yml")
      entry = Doubletrack::Baseline.load(baseline).entry(@finding["id"])
      expect(entry).to include("reason" => "intended", "author" => "A <a@example.com>", "title" => @finding["title"],
        "run_id" => "20261103T000000Z-1", "rails" => "8.0.5.1 → 8.1.4")
    end

    it "says Updated when the id was already accepted" do
      run_cli("accept", @finding["id"], "--reason", "one", "--author", "A", @app)
      code, out, = run_cli("accept", @finding["id"], "--reason", "two", "--author", "A", @app)
      expect(code).to eq(0)
      expect(out).to include("Updated #{@finding["id"]}")
    end

    it "honors --results and --baseline" do
      other = File.join(@app, "elsewhere.yml")
      code, _, err = run_cli("accept", @finding["id"], "--reason", "r", "--author", "A", "--results", @results, "--baseline", other)
      expect(code).to eq(0), err
      expect(File).to exist(other)
      expect(File).not_to exist(baseline)
    end

    it "refuses an id that isn't in the results, without writing anything" do
      code, _, err = run_cli("accept", "f-000000000000", "--reason", "r", "--author", "A", @app)
      expect(code).to eq(2)
      expect(err).to include("f-000000000000", "not found", "20261103T000000Z-1")
      expect(File).not_to exist(baseline)
    end

    it "requires an id and a non-blank reason" do
      expect(run_cli("accept", "--reason", "r", "--author", "A", @app).first).to eq(2)
      code, _, err = run_cli("accept", @finding["id"], "--author", "A", @app)
      expect(code).to eq(2)
      expect(err).to include("--reason")
      expect(run_cli("accept", @finding["id"], "--reason", "  ", "--author", "A", @app).first).to eq(2)
    end

    it "explains what to do when there are no results yet" do
      Dir.mktmpdir do |empty|
        code, _, err = run_cli("accept", "f-000000000000", "--reason", "r", "--author", "A", empty)
        expect(code).to eq(2)
        expect(err).to include("doubletrack run")
      end
    end
  end
end
