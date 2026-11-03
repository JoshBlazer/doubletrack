# frozen_string_literal: true

require "doubletrack/report/line_diff"

RSpec.describe Doubletrack::Report::LineDiff do
  def lines(text) = text.split(",")

  it "marks only the lines that differ" do
    ops = described_class.ops(lines("a,b,c,d"), lines("a,x,c,d"))
    expect(ops).to eq([[:eq, "a"], [:del, "b"], [:ins, "x"], [:eq, "c"], [:eq, "d"]])
  end

  it "handles insertions, deletions and empty sides" do
    expect(described_class.ops([], lines("a,b"))).to eq([[:ins, "a"], [:ins, "b"]])
    expect(described_class.ops(lines("a,b"), [])).to eq([[:del, "a"], [:del, "b"]])
    expect(described_class.ops(lines("a,c"), lines("a,b,c"))).to eq([[:eq, "a"], [:ins, "b"], [:eq, "c"]])
  end

  it "always rebuilds both sides exactly (property)" do
    random = Random.new(3)
    200.times do
      a = Array.new(random.rand(0..12)) { %w[p q r s][random.rand(4)] }
      b = Array.new(random.rand(0..12)) { %w[p q r s][random.rand(4)] }
      ops = described_class.ops(a, b)
      expect(ops.reject { |op, _| op == :ins }.map(&:last)).to eq(a)
      expect(ops.reject { |op, _| op == :del }.map(&:last)).to eq(b)
    end
  end

  it "folds long unchanged stretches but keeps context around changes" do
    a = (1..100).map(&:to_s)
    b = a.dup.tap { |x| x[50] = "changed" }
    folded = described_class.fold(described_class.ops(a, b), context: 3)
    expect(folded.first).to eq([:skip, 47])
    expect(folded[1..3].map(&:last)).to eq(%w[48 49 50])
    expect(folded[4..5]).to eq([[:del, "51"], [:ins, "changed"]])
    expect(folded.last).to eq([:skip, 46])
  end

  it "doesn't fold short outputs or short stretches" do
    ops = described_class.ops(lines("a,b,c,d,e"), lines("a,b,X,d,e"))
    expect(described_class.fold(ops)).to eq(ops)
  end
end
