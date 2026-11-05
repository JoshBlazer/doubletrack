# frozen_string_literal: true

require "doubletrack/twin/fds"

RSpec.describe Doubletrack::Twin::Fds do
  def pipes
    r1, w1 = IO.pipe
    r2, w2 = IO.pipe
    [r1, w2].each { |io| io.close_on_exec = false }
    # The wrappers take ownership of these fd numbers. Without this, GC finalizing r1/w2
    # later would close the numbers again, after they were reused by another file.
    [r1, w2].each { |io| io.autoclose = false }
    [{"DOUBLETRACK_FD_IN" => r1.fileno.to_s, "DOUBLETRACK_FD_OUT" => w2.fileno.to_s}, [w1, r2]]
  end

  # Bundler re-execs the twin when the app's lockfile was written by another Bundler
  # version (BUNDLED WITH); the pipes must survive that exec (seen on once-campfire).
  it "opens the protocol fds still inheritable, so a re-exec while loading the bundle keeps them" do
    env, others = pipes
    input, output = described_class.open(env)
    expect(input.close_on_exec?).to be(false)
    expect(output.close_on_exec?).to be(false)
    expect(output.sync).to be(true)
  ensure
    [input, output, *others].each { |io| io&.close unless io&.closed? }
  end

  # Subprocesses the app starts must not inherit the protocol pipes: a detached one
  # would keep fd 4 open, so the coordinator would see a timeout, not a crash.
  it "seals them close-on-exec once the bundle is loaded" do
    env, others = pipes
    input, output = described_class.open(env)
    described_class.seal(input, output)
    expect(input.close_on_exec?).to be(true)
    expect(output.close_on_exec?).to be(true)
  ensure
    [input, output, *others].each { |io| io&.close unless io&.closed? }
  end
end
