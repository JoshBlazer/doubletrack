# frozen_string_literal: true

require "json"
require "doubletrack/protocol"
require "doubletrack/twin/worker"

RSpec.describe Doubletrack::Twin::Worker do
  # An app exception whose message has an invalid byte used to make JSON.generate raise
  # in the twin, so the reply never arrived and the run aborted.
  it "sends replies that contain invalid UTF-8, scrubbed" do
    to_twin_r, to_twin_w = IO.pipe
    from_twin_r, from_twin_w = IO.pipe
    worker = described_class.new(input: to_twin_r, output: from_twin_w, started_at: 0, role: "control_a")
    bad = (+"unexpected token at '\xFF'").force_encoding(Encoding::UTF_8)
    expect(bad.valid_encoding?).to be(false)
    worker.send(:reply, {"id" => "c-000001"}, {"traces" => [{"exception" => {"message" => bad}}]})
    worker.send(:reply_error, {"id" => "c-000002"}, "session_failed", bad)
    reader = Doubletrack::Protocol::Reader.new(from_twin_r)
    first = reader.read(timeout: 5)
    second = reader.read(timeout: 5)
    expect(first.dig("payload", "traces", 0, "exception", "message")).to eq("unexpected token at '\uFFFD'")
    expect(second.dig("payload", "message")).to eq("unexpected token at '\uFFFD'")
  ensure
    [to_twin_r, to_twin_w, from_twin_r, from_twin_w].each { |io| io&.close unless io&.closed? }
  end
end
