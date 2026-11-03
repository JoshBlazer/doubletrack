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
    code, _, err = run_cli("run")
    expect(code).to eq(2)
    expect(err).to include("not implemented yet", "M3")
  end

  it "rejects unknown commands with exit 2" do
    expect(run_cli("frobnicate").first).to eq(2)
  end
end
