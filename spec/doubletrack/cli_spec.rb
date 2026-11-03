# frozen_string_literal: true

require "stringio"
require "doubletrack/cli"

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
    code, _, err = run_cli("accept", "f-123")
    expect(code).to eq(2)
    expect(err).to include("not implemented yet", "M4")
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
end
