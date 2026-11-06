# frozen_string_literal: true

require "open3"
require "uri"
require "tmpdir"
require "doubletrack/coordinator/twin_process"

RSpec.describe Doubletrack::Coordinator::TwinProcess do
  let(:work_dir) { Dir.mktmpdir("doubletrack-spec") }
  let(:fake_twin) { File.expand_path("../../support/fake_twin.rb", __dir__) }

  after { FileUtils.rm_rf(work_dir) }

  def twin(mode, **options)
    described_class.new(
      role: "control_a",
      app_root: work_dir,
      gemfile: File.join(work_dir, "Gemfile"),
      work_dir: work_dir,
      command: [RbConfig.ruby, fake_twin],
      env: {"FAKE_TWIN_MODE" => mode},
      **options
    )
  end

  it "boots, records hello, runs a session, and shuts down cleanly" do
    t = twin("happy")
    hello = t.start
    expect(hello).to include("role" => "control_a", "rails_version" => "0.0.fake")
    expect(hello["bundle_gemfile"]).to eq(File.join(work_dir, "Gemfile"))

    result = t.run_session("id" => "s1", "requests" => [{"method" => "GET", "path" => "/up"}])
    expect(result["session_id"]).to eq("s1")
    expect(Doubletrack::Protocol::Message.decode_body(result["traces"].first.dig("response", "body"))).to eq("GET /up")

    expect(t.stop).to be_success
  end

  it "does not leak RUBYOPT into the twin" do
    original = ENV["RUBYOPT"]
    ENV["RUBYOPT"] = "-W0"
    hello = twin("happy").tap(&:start)
    expect(hello.hello["rubyopt"]).to be_nil
  ensure
    ENV["RUBYOPT"] = original
    hello&.stop
  end

  # Regression (found by CI run 41552751273): `bundle exec` with a bundle path exports
  # GEM_HOME/GEM_PATH. A coordinator that never loaded Bundler passed them straight to
  # the twins, which then could not find the app's gems (RISKS R1).
  it "restores the pre-`bundle exec` environment for twins even when Bundler is not loaded" do
    script = <<~RUBY
      abort "precondition: Bundler must not be loaded" if defined?(Bundler::VERSION)
      require "doubletrack/coordinator/twin_process"
      twin = Doubletrack::Coordinator::TwinProcess.new(
        role: "control_a", app_root: #{work_dir.inspect}, gemfile: "Gemfile", work_dir: #{work_dir.inspect},
        command: [RbConfig.ruby, #{fake_twin.inspect}], env: {"FAKE_TWIN_MODE" => "happy"})
      hello = twin.start
      twin.stop
      puts "gem_home=\#{hello["gem_home"].inspect}"
    RUBY
    # Clear what would make RubyGems auto-load Bundler in the child (as bin/doubletrack-spike
    # run from a plain shell would be), but keep the leaked GEM_HOME and its BUNDLER_ORIG_ twin.
    leaked_env = {
      "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLER_SETUP" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
      "GEM_HOME" => "/leaked/by/bundle-exec",
      "BUNDLER_ORIG_GEM_HOME" => "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"
    }
    out, err, status = Open3.capture3(leaked_env, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script)
    expect(status).to be_success, err
    expect(out).to include("gem_home=nil")
  end

  # M10: Bundler.with_unbundled_env drops every BUNDLE_* variable, including settings the
  # user set on purpose (BUNDLE_WITH=postgresql for an optional group, BUNDLE_PATH in CI).
  it "passes the user's own Bundler settings to twins, and nothing Bundler set for this process" do
    original = {"BUNDLE_WITH" => "postgresql", "BUNDLE_WITHOUT" => "development", "BUNDLE_PATH" => "/vendor/bundle",
                "BUNDLE_DEPLOYMENT" => "true", "BUNDLE_GEMFILE" => "/coordinator/Gemfile", "BUNDLE_BIN_PATH" => "/x/bundle",
                "BUNDLER_SETUP" => "/x/setup", "PATH" => "/usr/bin"}
    expect(Doubletrack::Coordinator::TwinProcess.bundler_settings(original)).to eq(
      "BUNDLE_WITH" => "postgresql", "BUNDLE_WITHOUT" => "development", "BUNDLE_PATH" => "/vendor/bundle", "BUNDLE_DEPLOYMENT" => "true"
    )
  end

  it "is not corrupted by app output on stdout/stderr, which goes to the twin log" do
    t = twin("noisy")
    expect(t.start).to include("role" => "control_a")
    expect(t.stop).to be_success # file-backed stdout is block-buffered; read the log after exit
    expect(File.read(t.log_path)).to include("app noise 999", "stderr noise")
  end

  it "raises TwinCrashed with the log tail when the twin dies before hello" do
    expect { twin("crash_before_hello").start }.to raise_error(Doubletrack::TwinCrashed) { |error|
      expect(error.log_tail).to include("simulated boot crash")
      expect(error.message).to include("exit status 3")
    }
  end

  it "raises TwinTimeout and kills the twin when hello never arrives" do
    t = twin("hang", boot_timeout: 0.5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { t.start }.to raise_error(Doubletrack::TwinTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    expect(t).not_to be_alive
  end

  it "raises TwinTimeout when a request is never answered" do
    t = twin("hang_on_request", request_timeout: 0.5)
    t.start
    expect { t.run_session("id" => "s1", "requests" => []) }.to raise_error(Doubletrack::TwinTimeout)
    expect(t).not_to be_alive
  end

  it "surfaces boot_failed as TwinBootFailed" do
    expect { twin("boot_failed").start }
      .to raise_error(Doubletrack::TwinBootFailed, /simulated boot failure/)
  end

  it "surfaces error replies as TwinRequestFailed with the code" do
    t = twin("happy")
    t.start
    expect { t.request("prepare_snapshot", {}) }
      .to raise_error(Doubletrack::TwinRequestFailed) { |e| expect(e.code).to eq("not_implemented") }
  ensure
    t&.stop
  end

  it "raises TwinBootFailed (exit 2 territory) and leaks no fds when the twin can't be spawned" do
    t = described_class.new(role: "control_a", app_root: File.join(work_dir, "missing"), gemfile: "Gemfile",
      work_dir: work_dir, command: [RbConfig.ruby, fake_twin])
    # Compare fd sets, not counts: GC may close other specs' leftover pipes meanwhile.
    open_fds = -> { File.directory?("/proc/self/fd") ? Dir.children("/proc/self/fd") : [] }
    GC.start
    before = open_fds.call
    expect { t.start }.to raise_error(Doubletrack::TwinBootFailed, /could not start control_a/)
    expect(open_fds.call - before).to be_empty
  end

  it "shows a twin's error that has no reply_to (bad_message) instead of a reply_to mismatch" do
    t = twin("reject_requests")
    t.start
    expect { t.run_session("id" => "s1", "requests" => []) }
      .to raise_error(Doubletrack::TwinRequestFailed, /bad_message: frame exceeds/)
  ensure
    t&.stop
  end

  describe ".database_url" do
    {"space" => "/home/a b/w/control_a.sqlite3", "hash" => "/home/a#b/control_a.sqlite3",
     "percent" => "/tmp/%41/x.sqlite3", "unicode" => "/tmp/ü/x.sqlite3"}.each do |label, path|
      it "round-trips a path with a #{label}" do
        url = described_class.database_url(path)
        uri = URI.parse(url)
        expect(uri.scheme).to eq("sqlite3")
        expect(URI::DEFAULT_PARSER.unescape(uri.opaque || uri.path).force_encoding(Encoding::UTF_8)).to eq(path)
        expect(uri.fragment).to be_nil
      end
    end
  end

  it "rejects unknown roles" do
    expect { described_class.new(role: "x", app_root: work_dir, gemfile: "G", work_dir: work_dir) }
      .to raise_error(ArgumentError, /role/)
  end
end
