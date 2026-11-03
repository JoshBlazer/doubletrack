# frozen_string_literal: true

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
    expect(Doubletrack::Protocol::Message.decode_body(result["responses"].first["body"])).to eq("GET /up")

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

  it "rejects unknown roles" do
    expect { described_class.new(role: "x", app_root: work_dir, gemfile: "G", work_dir: work_dir) }
      .to raise_error(ArgumentError, /role/)
  end
end
