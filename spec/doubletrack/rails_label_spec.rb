# frozen_string_literal: true

require "doubletrack/rails_label"

# Apps that track Rails main (or any git ref) report the same Rails.version on both
# sides of an upgrade, e.g. 8.2.0.alpha → 8.2.0.alpha. The git revision tells them apart.
RSpec.describe Doubletrack::RailsLabel do
  describe ".label" do
    it "is the version alone for a released gem" do
      expect(described_class.label({"rails_version" => "8.1.4"})).to eq("8.1.4")
    end

    it "adds a short git revision when Rails was loaded from git" do
      twin = {"rails_version" => "8.2.0.alpha", "rails_revision" => "1a02651ac37fb64b4de2a2b73461d86acf9c98fb"}
      expect(described_class.label(twin)).to eq("8.2.0.alpha (1a02651ac3)")
    end

    it "is empty for a missing twin" do
      expect(described_class.label(nil)).to eq("")
    end
  end

  describe ".check!" do
    let(:old) { {"rails_version" => "8.2.0.alpha", "rails_revision" => "1a02651ac37fb64b4de2a2b73461d86acf9c98fb"} }
    let(:new) { {"rails_version" => "8.2.0.alpha", "rails_revision" => "e3d5c569d217c56c022b04acb127a8c24dbe9685"} }

    it "accepts the same version at two different revisions" do
      expect { described_class.check!(old, old, new) }.not_to raise_error
    end

    it "accepts two released versions" do
      expect { described_class.check!({"rails_version" => "8.0.5"}, {"rails_version" => "8.0.5"}, {"rails_version" => "8.1.4"}) }.not_to raise_error
    end

    it "rejects a candidate on the very same version and revision (RISKS R1)" do
      expect { described_class.check!(old, old, old) }
        .to raise_error(Doubletrack::Error, /dual boot not effective: candidate B also loaded Rails 8\.2\.0\.alpha \(1a02651ac3\)/)
    end

    it "rejects controls on different revisions" do
      expect { described_class.check!(old, new, new) }
        .to raise_error(Doubletrack::Error, /control A \(8\.2\.0\.alpha \(1a02651ac3\)\) and control A′ \(8\.2\.0\.alpha \(e3d5c569d2\)\) must run the same Rails/)
    end
  end
end
