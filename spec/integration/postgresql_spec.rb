# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# M10 exit check (ADR 0037): shop on PostgreSQL. Runs when SHOP_DATABASE_URL points at a
# PostgreSQL 13+ server and BUNDLE_WITH=postgresql installed shop's pg gem (CI job
# "integration shop on PostgreSQL").
RSpec.describe "doubletrack on shop with PostgreSQL", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  def cli(root, *args)
    Open3.capture3(RbConfig.ruby, File.join(root, "exe/doubletrack"), *args, chdir: root)
  end

  def in_app(app, gemfile, *command)
    Bundler.with_unbundled_env do
      env = {"BUNDLE_GEMFILE" => File.join(app, gemfile), "BUNDLE_WITH" => "postgresql", "SHOP_DATABASE_URL" => ENV["SHOP_DATABASE_URL"]}
      Open3.capture2e(env, "bundle", "exec", *command, chdir: app)
    end
  end

  before(:all) do
    skip "set SHOP_DATABASE_URL (and BUNDLE_WITH=postgresql) to run the PostgreSQL checks" if ENV["SHOP_DATABASE_URL"].to_s.empty?

    @tmp = Dir.mktmpdir("doubletrack-m10-")
    @stdout, @stderr, @status = cli(root, "run", shop, "--out", File.join(@tmp, "runs"), "--seed", "42",
      "--baseline", File.join(@tmp, "baseline.yml"))
    @results = Dir.glob(File.join(@tmp, "runs", "*")).find { |d| File.directory?(d) }
    @run = JSON.parse(File.read(File.join(@results, "run.json")))
    @findings = JSON.parse(File.read(File.join(@results, "findings.json")))["findings"]
    @repros = JSON.parse(File.read(File.join(@results, "repros.json")))
  end

  after(:all) { FileUtils.rm_rf(@tmp) if @tmp }

  it "replays every twin on its own PostgreSQL database" do
    expect(@status.exitstatus).to eq(1), "#{@stdout}\n#{@stderr}"
    %w[control_a control_a_prime candidate_b].each do |role|
      expect(@run.dig("twins", role, "database", "adapter")).to eq("postgresql")
      expect(@run.dig("twins", role, "database", "name")).to match(/\Adt_\h{10}_#{role}\z/)
    end
    expect(@run.dig("snapshots", "default", "tables")).to include("orders" => 0)
  end

  it "is deterministic: control A and control A′ agree everywhere (M2), as on SQLite" do
    expect(@run.dig("noise", "a_vs_a_prime_differences")).to eq(0)
  end

  it "finds shop's change with a verified reproduction (M3/M4), with the same finding id as on SQLite" do
    expect(@findings.map { |f| f["id"] }).to eq(["f-bb3068808cf1"])
    expect(@repros["repros"].map { |r| r["status"] }).to eq(["reproduced"])
    expect(@repros["repros"].first["snapshot"]).to end_with(".pg.json")
  end

  it "ships a reproduction that passes on the current Rails and fails on the next, run for real" do
    file = File.join(@results, @repros["repros"].first["file"])
    output, status = in_app(shop, "Gemfile", "ruby", "-I", File.join(root, "lib"), "-Itest", file)
    expect(status).to be_success, output
    output, status = in_app(shop, "Gemfile.next", "ruby", "-I", File.join(root, "lib"), "-Itest", file)
    expect(status).not_to be_success, output
    expect(output).to include("unexpected end of input")
  end

  it "leaves no database behind" do
    script = 'require "pg"; c = PG.connect(ENV.fetch("SHOP_DATABASE_URL").sub(%r{/[^/]*\z}, "/postgres")); ' \
             'puts c.exec("SELECT datname FROM pg_database WHERE datname LIKE \'dt\\_%\'").column_values(0).join(",")'
    output, status = in_app(shop, "Gemfile", "ruby", "-e", script)
    expect(status).to be_success, output
    expect(output.strip).to eq("")
  end
end
