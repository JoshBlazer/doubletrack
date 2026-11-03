# frozen_string_literal: true

require "tmpdir"
require "doubletrack/coordinator/run"

RSpec.describe Doubletrack::Coordinator::Run do
  # Two runs with the same --seed in the same second must not share a results directory.
  it "picks a fresh results directory when the run id is taken" do
    Dir.mktmpdir do |out|
      first = described_class.claim_dir(out, "20261103T000000Z-42")
      second = described_class.claim_dir(out, "20261103T000000Z-42")
      expect(File.basename(first)).to eq("20261103T000000Z-42")
      expect(File.basename(second)).to eq("20261103T000000Z-42-2")
      expect(File).to be_directory(second)
    end
  end
end
