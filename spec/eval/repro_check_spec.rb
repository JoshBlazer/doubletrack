# frozen_string_literal: true

require_relative "../../eval/harness"

RSpec.describe DoubletrackEval::ReproCheck do
  describe ".parse_minitest" do
    it "maps verbose Minitest lines to finding ids and pass/fail" do
      ids = %w[f-bb3068808cf1 f-0000000000aa f-0000000000bb]
      output = <<~OUT
        Run options: -v --seed 1

        # Running:

        DoubletrackReproFBb3068808cf1Test#test_keeps_the_rails_8_0_5_1_behavior = 0.31 s = .
        DoubletrackReproF0000000000aaTest#test_keeps_the_rails_8_0_5_1_behavior = 0.02 s = F
        DoubletrackReproF0000000000bbTest#test_keeps_the_rails_8_0_5_1_behavior = 0.02 s = E

        Finished in 0.35s
      OUT
      expect(described_class.parse_minitest(output, ids)).to eq(
        "f-bb3068808cf1" => :pass, "f-0000000000aa" => :fail, "f-0000000000bb" => :error
      )
    end

    it "marks ids that never ran as missing" do
      expect(described_class.parse_minitest("", ["f-bb3068808cf1"])).to eq("f-bb3068808cf1" => :missing)
    end
  end

  describe ".score" do
    it "counts repros verified in the run, passing on A and failing on B" do
      repros = [{"finding_id" => "f-1", "status" => "reproduced"}, {"finding_id" => "f-2", "status" => "not_reproduced"}]
      score = described_class.score(repros, {"f-1" => :pass, "f-2" => :pass}, {"f-1" => :fail, "f-2" => :pass})
      expect(score).to eq("generated" => 2, "verified_in_run" => 1, "pass_on_current" => 2, "fail_on_next" => 1,
        "confirmed" => 1, "unconfirmed" => ["f-2"])
    end
  end
end
