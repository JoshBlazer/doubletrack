# frozen_string_literal: true

require "tmpdir"
require_relative "../../eval/harness"

# M3 exit check, part 2: the planted-change fixture yields the expected findings and the
# clean fixture yields none (ADR 0020). `make eval` runs the same harness.
RSpec.describe "Eval on fixtures/apps/planted", :integration do
  before(:all) do
    @out = Dir.mktmpdir("doubletrack-eval-")
    @report = DoubletrackEval::Harness.new(out_dir: @out, seed: 7).call
  end

  after(:all) { FileUtils.rm_rf(@out) }

  it "catches every planted change (recall 1.0)" do
    changes = @report["apps"]["changes"]
    expect(changes["missed"]).to eq([]), JSON.pretty_generate(changes)
    expect(changes["recall"]).to eq(1.0)
  end

  it "reports nothing it should not (precision 1.0)" do
    changes = @report["apps"]["changes"]
    expect(changes["unexpected"]).to eq([]), JSON.pretty_generate(changes["unexpected"])
    expect(changes["precision"]).to eq(1.0)
  end

  it "finds nothing in the clean app" do
    expect(@report["apps"]["clean"]["findings"]).to eq(0), JSON.pretty_generate(@report["apps"]["clean"])
  end

  it "filters planted noise instead of reporting it" do
    expect(@report["apps"]["changes"]["noise_suppressed"]).to be > 0
    expect(@report["apps"]["clean"]["noise_suppressed"]).to be > 0
  end

  it "gives every planted finding a reproduction that passes on the current Rails and fails on the next (M4)" do
    repros = @report["apps"]["changes"]["repros"]
    expect(repros["generated"]).to eq(@report["apps"]["changes"]["findings"]), JSON.pretty_generate(repros)
    expect(repros["confirmed"]).to eq(repros["generated"]), JSON.pretty_generate(repros)
  end

  it "passes overall" do
    expect(@report["pass"]).to be(true)
  end
end
