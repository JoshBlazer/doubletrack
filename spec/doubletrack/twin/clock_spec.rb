# frozen_string_literal: true

require "date"
require "doubletrack/twin/clock"

RSpec.describe Doubletrack::Twin::Clock do
  let(:instant) { Time.utc(2026, 1, 15, 9, 30, 0, 123_456.789r) }

  before { described_class.install! }

  it "freezes Time.now, Time.new, Date.today and DateTime.now inside the block, without truncation" do
    described_class.freeze_at(instant) do
      expect(Time.now).to eq(instant)
      expect(Time.now.nsec).to eq(instant.nsec)
      expect(Time.new).to eq(instant)
      expect(Date.today).to eq(Date.new(2026, 1, 15))
      expect(DateTime.now.to_time).to eq(instant)
    end
  end

  it "supports Time.now(in:)" do
    described_class.freeze_at(instant) do
      now = Time.now(in: "+09:00")
      expect(now).to eq(instant)
      expect(now.utc_offset).to eq(9 * 3600)
    end
  end

  it "leaves Time.new with arguments alone" do
    described_class.freeze_at(instant) do
      expect(Time.new(2000, 1, 1, 0, 0, 0, "+00:00").year).to eq(2000)
    end
  end

  it "nests and restores the outer time, even when the block raises" do
    later = instant + 60
    described_class.freeze_at(instant) do
      expect {
        described_class.freeze_at(later) do
          expect(Time.now).to eq(later)
          raise "boom"
        end
      }.to raise_error("boom")
      expect(Time.now).to eq(instant)
    end
    expect(described_class.frozen).to be_nil
  end

  it "does not touch the clock outside a block" do
    expect(described_class.frozen).to be_nil
    expect((Time.now - Process.clock_gettime(Process::CLOCK_REALTIME)).abs).to be < 5
  end

  it "returns a fresh object each time, so callers cannot change the frozen instant" do
    described_class.freeze_at(instant) do
      Time.now.localtime("+05:00")
      expect(Time.now.utc_offset).to eq(Time.at(0).utc_offset)
      expect(Time.now).not_to equal(Time.now)
    end
  end

  it "is idempotent to install" do
    described_class.install!
    described_class.freeze_at(instant) { expect(Time.now).to eq(instant) }
    expect(Time.singleton_class.ancestors.count(described_class::TimeMethods)).to eq(1)
  end

  it "accepts ISO 8601 strings" do
    described_class.freeze_at("2026-01-15T09:30:00Z") { expect(Time.now).to eq(Time.utc(2026, 1, 15, 9, 30)) }
  end
end
