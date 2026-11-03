# frozen_string_literal: true

require "doubletrack/coordinator/parallel"

RSpec.describe Doubletrack::Coordinator do
  describe ".parallel_map" do
    it "returns results in input order" do
      expect(described_class.parallel_map([3, 1, 2]) { |n| sleep(n * 0.01) && n * 10 }).to eq([30, 10, 20])
    end

    # A twin whose thread fails must not leave the others mid-request: the next request
    # (or stop) on them would race with a reply still in flight.
    it "waits for every item before raising the first error, and prints no thread backtraces" do
      finished = []
      expect {
        expect {
          described_class.parallel_map(%w[fails slow]) do |name|
            raise Doubletrack::TwinRequestFailed.new("boom", role: name) if name == "fails"

            sleep 0.2
            finished << name
          end
        }.to raise_error(Doubletrack::TwinRequestFailed, "boom")
      }.not_to output.to_stderr
      expect(finished).to eq(["slow"])
    end
  end
end
