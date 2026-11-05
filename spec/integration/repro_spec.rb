# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "doubletrack/specgen"

# M4 exit check: a generated spec passes on old and fails on new (RSpec and Minitest,
# run for real with `bundle exec` on both Gemfiles), and `accept` suppresses the finding
# on the next run.
RSpec.describe "Reproduction specs and baseline on fixtures/apps/shop", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  def cli(root, *args)
    Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), *args, chdir: root)
  end

  # Runs a command in the shop app under its own bundle, like a user would.
  def in_app(app, gemfile, *command)
    Bundler.with_unbundled_env do
      Open3.capture2e({"BUNDLE_GEMFILE" => File.join(app, gemfile)}, "bundle", "exec", *command, chdir: app)
    end
  end

  before(:all) do
    @tmp = Dir.mktmpdir("doubletrack-m4-")
    @baseline = File.join(@tmp, "doubletrack.baseline.yml")
    @stdout, @stderr, @status = cli(root, "run", shop, "--out", File.join(@tmp, "runs"), "--seed", "42", "--baseline", @baseline)
    @results = Dir.glob(File.join(@tmp, "runs", "*")).find { |d| File.directory?(d) }
    stored = JSON.parse(File.read(File.join(@results, "findings.json")))
    @findings = stored["findings"]
    @changes = stored["changes"]
    @repros = JSON.parse(File.read(File.join(@results, "repros.json")))
  end

  after(:all) { FileUtils.rm_rf(@tmp) }

  it "finds at least one difference on shop (exit 1)" do
    expect(@status.exitstatus).to eq(1), "#{@stdout}\n#{@stderr}"
    expect(@findings).not_to be_empty
  end

  it "verifies a reproduction for every new finding during the run" do
    expect(@repros["framework"]).to eq("minitest") # shop has test/, no spec/
    expect(@repros["repros"].map { |r| r["finding_id"] }).to match_array(@findings.map { |f| f["id"] })
    @repros["repros"].each do |r|
      expect(r["status"]).to eq("reproduced"), JSON.pretty_generate(r)
      expect(r["requests"].size).to be <= r["requests_before"]
    end
    expect(@stdout).to match(/Reproductions: \d+ verified/)
  end

  # M7 exit check (ADR 0031, 0032): findings grouped into changes, each with a likely cause
  # found on this machine. Shop's one difference is a JSON parser message that comes from
  # the json gem Rails 8.1's bundle pins.
  it "groups the findings into changes and names the json gem as the likely cause" do
    expect(@changes.flat_map { |c| c["findings"] }).to match_array(@findings.map { |f| f["id"] })
    message = @changes.find { |c| c["path"] == "exception.message" }
    expect(message).not_to be_nil, JSON.pretty_generate(@changes)
    expect(message["causes"].map { |c| c["dependency"] }).to include("json")
    expect(@stdout).to match(/Findings: \d+ new in \d+ changes?/)
    expect(@stdout).to include("likely cause: json")
  end

  context "the generated Minitest file, run in place with the app's bundle" do
    let(:repro) { @repros["repros"].first }
    let(:file) { File.join(@results, repro["file"]) }

    it "passes on the current Rails" do
      output, status = in_app(shop, "Gemfile", "ruby", "-Itest", file)
      expect(status.exitstatus).to eq(0), output
      expect(output).to include("1 runs, 1 assertions, 0 failures, 0 errors")
    end

    it "fails on the next Rails, showing the old and new values" do
      output, status = in_app(shop, "Gemfile.next", "ruby", "-Itest", file)
      expect(status.exitstatus).to eq(1), output
      expect(output).to include("1 failures")
      expect(output).to include(repro["expected"].inspect) unless repro["expected_absent"]
    end
  end

  context "the generated Minitest file, after the app's own test_helper booted Rails in the test environment" do
    it "still passes on the current Rails and fails on the next (ADR 0022: the replay runs in its own twin)" do
      file = File.join(@results, @repros["repros"].first["file"])
      script = 'require "test_helper"; warn "booted " + Rails.env; require ARGV.shift'
      output, status = in_app(shop, "Gemfile", "ruby", "-Itest", "-e", script, file)
      expect(output).to include("booted test")
      expect(status.exitstatus).to eq(0), output
      output, status = in_app(shop, "Gemfile.next", "ruby", "-Itest", "-e", script, file)
      expect(status.exitstatus).to eq(1), output
    end
  end

  context "the same reproduction rendered as an RSpec spec" do
    before(:all) do
      repro = @repros["repros"].first
      run = JSON.parse(File.read(File.join(@results, "run.json")))
      spec_dir = File.join(@tmp, "rspec", "spec", "doubletrack")
      FileUtils.mkdir_p(File.join(spec_dir, "snapshots"))
      minitest_dir = File.dirname(File.join(@results, repro["file"]))
      FileUtils.cp(File.join(minitest_dir, repro["snapshot"]), File.join(spec_dir, repro["snapshot"]))
      writer = Doubletrack::Specgen::Writer.new(framework: "rspec", run_id: run["run_id"],
        from: run.dig("twins", "control_a", "rails_version"), to: run.dig("twins", "candidate_b", "rails_version"),
        gemfile: "Gemfile", next_gemfile: "Gemfile.next", doubletrack_version: Doubletrack::VERSION)
      @rspec_file = File.join(spec_dir, "#{repro["finding_id"]}_spec.rb")
      File.write(@rspec_file, writer.render(repro))
    end

    it "passes on the current Rails and fails on the next" do
      output, status = in_app(shop, "Gemfile", "rspec", @rspec_file)
      expect(status.exitstatus).to eq(0), output
      expect(output).to include("1 example, 0 failures")

      output, status = in_app(shop, "Gemfile.next", "rspec", @rspec_file)
      expect(status.exitstatus).to eq(1), output
      expect(output).to include("1 example, 1 failure")
    end
  end

  context "accept, then run again" do
    before(:all) do
      @accepted = @findings.map { |f| f["id"] }
      @accept_out = @changes.map { |c| c["id"] }.map do |id| # accept whole changes (M7)
        cli(root, "accept", id, "--reason", "integration test", "--author", "Doubletrack CI <ci@example.invalid>",
          "--results", @results, "--baseline", @baseline, shop)
      end
      @stdout2, @stderr2, @status2 = cli(root, "run", shop, "--out", File.join(@tmp, "runs2"), "--seed", "42", "--baseline", @baseline)
      @results2 = Dir.glob(File.join(@tmp, "runs2", "*")).find { |d| File.directory?(d) }
    end

    it "records every accepted finding in the baseline file" do
      @accept_out.each { |out, err, status| expect(status.exitstatus).to eq(0), "#{out}\n#{err}" }
      text = File.read(@baseline)
      @accepted.each { |id| expect(text).to include(id) }
    end

    it "reports them as accepted, not new, and exits 0" do
      expect(@status2.exitstatus).to eq(0), "#{@stdout2}\n#{@stderr2}"
      expect(@stdout2).to include("Findings: 0 new", "#{@accepted.size} accepted")
      findings = JSON.parse(File.read(File.join(@results2, "findings.json")))["findings"]
      expect(findings.map { |f| f["id"] }).to match_array(@accepted)
      expect(findings).to all(include("accepted"))
      run = JSON.parse(File.read(File.join(@results2, "run.json")))
      expect(run["verdict"]).to eq("ready")
      expect(run.dig("baseline", "stale")).to eq([])
    end

    it "generates no reproductions for accepted findings" do
      expect(JSON.parse(File.read(File.join(@results2, "repros.json")))["repros"]).to eq([])
    end
  end
end
