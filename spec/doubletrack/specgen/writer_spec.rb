# frozen_string_literal: true

require "json"
require "doubletrack/specgen"

RSpec.describe Doubletrack::Specgen::Writer do
  let(:context) do
    {run_id: "20261103T072146Z-42", from: "8.0.5.1", to: "8.1.4", gemfile: "Gemfile", next_gemfile: "Gemfile.next",
     snapshot: "snapshots/1a2b3c4d5e6f.sqlite3", doubletrack_version: "0.0.1"}
  end

  let(:repro) do
    {
      "finding_id" => "f-bb3068808cf1",
      "title" => "GET /orders/:id(.:format): exception.message changed",
      "severity" => "user-visible",
      "session_id" => "unstubbed-rate",
      "seed" => 1234567890123,
      "started_at" => "2026-01-01T00:00:00Z",
      "perform_jobs" => true,
      "http_stubs" => [],
      "requests" => [{"method" => "GET", "path" => "/orders/1/rate", "params" => {}, "headers" => {}, "offset_ms" => 1000}],
      "kept_request_indexes" => [1],
      "requests_before" => 2,
      "segments" => ["exception", "message"],
      "op" => "changed",
      "expected" => "unexpected token at ''",
      "expected_absent" => false,
      "normalize" => {"ignored_headers" => [], "ignored_columns" => []},
      "status" => "reproduced",
      "observed" => {"control_a" => {"value" => "unexpected token at ''"},
                     "control_a_prime" => {"value" => "unexpected token at ''"},
                     "candidate_b" => {"value" => "unexpected end of input"}}
    }
  end

  def render(framework, r = repro)
    described_class.new(framework: framework, **context).render(r)
  end

  def compiles?(source)
    RubyVM::InstructionSequence.compile(source)
    true
  end

  describe "RSpec output" do
    subject(:text) { render("rspec") }

    it "is valid Ruby that requires the shipped helper with a helpful LoadError" do
      expect(compiles?(text)).to be(true)
      expect(text).to include('require "doubletrack/repro"', "LoadError",
        'gem "doubletrack", github: "JoshBlazer/doubletrack", require: false, group: :test')
    end

    it "describes the finding and asserts the old value at the finding's path on the last request" do
      expect(text).to include("RSpec.describe", "f-bb3068808cf1", "GET /orders/:id(.:format): exception.message changed")
      expect(text).to include(%{expect(replay.last.at("exception", "message")).to eql("unexpected token at ''")})
    end

    it "restores the snapshot relative to the spec file and replays the minimized requests with the run's seed" do
      expect(text).to include(%{File.expand_path("snapshots/1a2b3c4d5e6f.sqlite3", __dir__)})
      expect(text).to include("seed: 1234567890123", %(started_at: "2026-01-01T00:00:00Z"), "perform_jobs: true")
      expect(text).to include(%("path" => "/orders/1/rate"))
    end

    it "explains how to run it on both versions and what was verified" do
      expect(text).to include("bundle exec rspec", "BUNDLE_GEMFILE=Gemfile.next bundle exec rspec")
      expect(text).to include("passes on Rails 8.0.5.1", "fails on Rails 8.1.4", "Verified", "20261103T072146Z-42")
      expect(text).to include("2 → 1 request")
    end

    it "asserts ABSENT for an added path and be_nil for a null" do
      added = render("rspec", repro.merge("expected" => nil, "expected_absent" => true, "op" => "added",
        "segments" => ["response", "headers", "date"]))
      expect(added).to include(%{expect(replay.last.at("response", "headers", "date")).to be(Doubletrack::Repro::ABSENT)})
      null = render("rspec", repro.merge("expected" => nil))
      expect(null).to include(%{expect(replay.last.at("exception", "message")).to be_nil})
    end

    it "passes integer segments as integers" do
      text = render("rspec", repro.merge("segments" => ["sql_writes", 0, "binds", "name"]))
      expect(text).to include(%{replay.last.at("sql_writes", 0, "binds", "name")})
    end

    it "includes normalization options only when the run used them" do
      expect(text).not_to include("ignored_headers")
      with = render("rspec", repro.merge("normalize" => {"ignored_headers" => ["x-version"], "ignored_columns" => []}))
      expect(with).to include(%(ignored_headers: ["x-version"]))
      expect(compiles?(with)).to be(true)
    end

    it "says plainly when the reproduction was not verified" do
      text = render("rspec", repro.merge("status" => "not_reproduced"))
      expect(text).to include("NOT verified")
      expect(text).not_to include("Verified in run")
    end
  end

  describe "Minitest output" do
    subject(:text) { render("minitest") }

    it "is valid Ruby with a constant-safe class name and a strict comparison" do
      expect(compiles?(text)).to be(true)
      expect(text).to include('require "minitest/autorun"', "class DoubletrackReproFBb3068808cf1Test < Minitest::Test")
      expect(text).to include(%(expected = "unexpected token at ''"), %{actual = replay.last.at("exception", "message")})
      expect(text).to include("assert(Doubletrack::Repro.same?(expected, actual), message { diff(expected, actual) })")
      expect(text).to include("bundle exec ruby -Itest", "BUNDLE_GEMFILE=Gemfile.next bundle exec ruby -Itest")
    end

    it "names the test after the old Rails, without runs of underscores for a git revision label" do
      text = described_class.new(framework: "minitest", **context.merge(from: "8.2.0.alpha (e3d5c569d2)")).render(repro)
      expect(text).to include("def test_keeps_the_rails_8_2_0_alpha_e3d5c569d2_behavior")
    end

    it "uses assert_nil for null and assert_same ABSENT for added paths" do
      expect(render("minitest", repro.merge("expected" => nil))).to include(%{assert_nil(replay.last.at("exception", "message"))})
      added = render("minitest", repro.merge("expected" => nil, "expected_absent" => true))
      expect(added).to include(%{assert_same(Doubletrack::Repro::ABSENT, replay.last.at("exception", "message"))})
    end
  end

  # Verification compares by JSON type (Repro.same?: 1 is not 1.0). The generated
  # assertion must be just as strict, or a "verified" spec could pass on the next Rails.
  describe "strictness" do
    let(:typed) { repro.merge("segments" => ["response", "body", "total"], "expected" => {"total" => 1}) }

    it "uses eql (not eq) in RSpec, so {total: 1} does not match {total: 1.0}" do
      expect(render("rspec", typed)).to include(%{to eql({"total" => 1})})
      expect({"total" => 1}).not_to eql({"total" => 1.0})
    end

    it "uses Repro.same? in Minitest" do
      text = render("minitest", typed)
      expect(text).to include(%(expected = {"total" => 1}), "Doubletrack::Repro.same?(expected, actual)")
      expect(text).not_to include("assert_equal")
    end
  end

  # Titles, ids and versions come from the app's responses (JSON keys appear in paths).
  # A newline must never end the comment and turn the rest into live code.
  describe "comment safety" do
    hostile = "GET /x: response.body.x\nputs(:INJECTED)\n# changed"

    %w[rspec minitest].each do |framework|
      it "keeps a hostile title inside comments and strings (#{framework})" do
        text = render(framework, repro.merge("title" => hostile, "severity" => "cosmetic\nraise"))
        expect(compiles?(text)).to be(true)
        code = text.lines.reject { |l| l.lstrip.start_with?("#") }.join
        expect(code).not_to match(/^\s*puts\(:INJECTED\)/)
        expect(code).not_to match(/^\s*raise$/)
        expect(text).to include("\\nputs(:INJECTED)")
      end
    end
  end

  it "rejects unknown frameworks" do
    expect { described_class.new(framework: "cucumber", **context) }.to raise_error(ArgumentError, /cucumber/)
  end

  describe ".literal" do
    values = [
      "plain",
      %(quote " and ' and \\ and \#{interpolation} and #) + "@ivar",
      "multi\nline\ttab ✓ ünïcode",
      42, -7, 3.25, 1.0, true, false, nil,
      {"a" => [1, {"b" => nil}], "c" => "d"},
      [{"x" => 1.5}, "y"],
      "x" * 400,
      {"long" => "y" * 400, "n" => [1, 2, 3]}
    ]

    values.each_with_index do |value, i|
      it "round-trips value ##{i} through eval" do
        literal = described_class.literal(value)
        expect(eval(literal)).to eq(value) # rubocop:disable Security/Eval -- the point of the test
        expect(eval(literal).class).to eq(value.class) # rubocop:disable Security/Eval
      end
    end

    it "uses a JSON heredoc for long values and inspect for short ones" do
      expect(described_class.literal("short")).to eq(%("short"))
      expect(described_class.literal("x" * 400)).to include("JSON.parse(<<~'EXPECTED'")
    end
  end
end
