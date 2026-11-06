# frozen_string_literal: true

require "doubletrack/doctor"
require "fileutils"
require "tmpdir"

RSpec.describe Doubletrack::Doctor do
  around { |ex| Dir.mktmpdir("dt-doctor") { |dir| @app = dir and ex.run } }

  def write(name, text)
    path = File.join(@app, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def lock(rails, extra = "")
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (#{rails})
          sqlite3 (2.7.3)
      #{extra}
      PLATFORMS
        ruby

      DEPENDENCIES
        rails

      BUNDLED WITH
         2.6.9
    LOCK
  end

  before do
    write("Gemfile", %(gem "rails"\n))
    write("Gemfile.next", %(gem "rails"\n))
    write("Gemfile.lock", lock("8.0.5.1"))
    write("Gemfile.next.lock", lock("8.1.4"))
    write("config/database.yml", "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n")
    write("db/schema.rb", "ActiveRecord::Schema.define {}\n")
    write("doubletrack/sessions/s.jsonl", "{}\n")
  end

  def checks(**options)
    described_class.new(@app, boot: false, bundle_check: ->(_gemfile) { [true, ""] }, **options).checks.to_h { |c| [c["name"], c] }
  end

  it "passes a well set-up app" do
    result = checks
    expect(result.values.map { |c| c["status"] }.uniq - ["ok"]).to eq([]), result.values.reject { |c| c["status"] == "ok" }.inspect
    expect(result.keys).to include("platform", "ruby", "dual boot", "rails versions", "bundles", "database", "http clients", "sessions", "git")
    expect(result["rails versions"]["detail"]).to eq("8.0.5.1 → 8.1.4")
  end

  it "fails a missing next lockfile, with the command that creates it" do
    FileUtils.rm(File.join(@app, "Gemfile.next.lock"))
    c = checks["dual boot"]
    expect(c).to include("status" => "fail")
    expect(c["detail"]).to include("Gemfile.next.lock")
    expect(c["fix"]).to include("BUNDLE_GEMFILE=Gemfile.next bundle install")
  end

  it "fails when both lockfiles resolve the same Rails, and warns on a pair that isn't adjacent" do
    write("Gemfile.next.lock", lock("8.0.5.1"))
    expect(checks["rails versions"]).to include("status" => "fail")
    write("Gemfile.next.lock", lock("8.2.0"))
    expect(checks["rails versions"]).to include("status" => "warn")
  end

  it "fails a bundle that isn't installed, with Bundler's message" do
    c = described_class.new(@app, boot: false, bundle_check: ->(g) { g.end_with?(".next") ? [false, "Could not find rails-8.1.4 in locally installed gems"] : [true, ""] })
      .checks.find { |x| x["name"] == "bundles" }
    expect(c["status"]).to eq("fail")
    expect(c["detail"]).to include("Gemfile.next", "Could not find rails-8.1.4")
  end

  it "accepts PostgreSQL with the pg gem (M10), fails it without, and fails other adapters and a missing db/schema.rb" do
    write("config/database.yml", "test:\n  adapter: postgresql\n  database: app_test\n")
    expect(checks["database"]).to include("status" => "fail")
    expect(checks["database"]["detail"]).to include("pg gem")
    write("Gemfile.lock", lock("8.0.5.1", "    pg (1.7.0)\n"))
    expect(checks["database"]).to include("status" => "ok")
    expect(checks["database"]["detail"]).to include("PostgreSQL")
    write("config/database.yml", "test:\n  adapter: mysql2\n  database: app_test\n")
    expect(checks["database"]).to include("status" => "fail")
    expect(checks["database"]["detail"]).to include("mysql2")
    write("config/database.yml", "test:\n  primary:\n    adapter: sqlite3\n    database: db/test.sqlite3\n")
    FileUtils.rm(File.join(@app, "db/schema.rb"))
    expect(checks["database"]["detail"]).to include("db/schema.rb")
  end

  it "warns about HTTP clients that bypass Net::HTTP, a missing sessions directory and another Ruby" do
    write("Gemfile.lock", lock("8.0.5.1", "    httpx (1.4.0)\n"))
    FileUtils.rm_rf(File.join(@app, "doubletrack"))
    write(".ruby-version", "2.7.8\n")
    result = checks
    expect(result["http clients"]).to include("status" => "warn")
    expect(result["http clients"]["detail"]).to include("httpx")
    expect(result["sessions"]).to include("status" => "warn")
    expect(result["sessions"]["fix"]).to include("doubletrack capture")
    expect(result["ruby"]).to include("status" => "warn")
    expect(result["ruby"]["detail"]).to include("2.7.8", RUBY_VERSION)
  end

  it "summarizes: exit 0 with only warnings, 1 with a failure" do
    expect(described_class.exit_code(checks.values)).to eq(0)
    FileUtils.rm(File.join(@app, "Gemfile.next"))
    expect(described_class.exit_code(checks.values)).to eq(1)
  end
end
