# frozen_string_literal: true

require "doubletrack/twin/fds"

RSpec.describe Doubletrack::Twin::Fds do
  # Subprocesses the app starts must not inherit the protocol pipes: a detached one
  # would keep fd 4 open, so the coordinator would see a timeout, not a crash.
  it "opens the protocol fds close-on-exec" do
    r1, w1 = IO.pipe
    r2, w2 = IO.pipe
    [r1, w2].each { |io| io.close_on_exec = false }
    input, output = described_class.open("DOUBLETRACK_FD_IN" => r1.fileno.to_s, "DOUBLETRACK_FD_OUT" => w2.fileno.to_s)
    expect(input.close_on_exec?).to be(true)
    expect(output.close_on_exec?).to be(true)
    expect(output.sync).to be(true)
  ensure
    [input, output, w1, r2].each { |io| io&.close unless io&.closed? }
  end
end
