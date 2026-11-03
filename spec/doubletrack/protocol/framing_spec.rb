# frozen_string_literal: true

require "doubletrack/protocol"

RSpec.describe "Doubletrack::Protocol framing" do
  let(:pipe) { IO.pipe }
  let(:reader) { Doubletrack::Protocol::Reader.new(pipe[0]) }
  let(:writer) { Doubletrack::Protocol::Writer.new(pipe[1]) }

  after { pipe.each { |io| io.close unless io.closed? } }

  def message(id, payload = {})
    Doubletrack::Protocol::Message.build(id: id, type: "result", payload: payload)
  end

  it "round-trips messages in order" do
    writer.write(message("t-1", "n" => 1))
    writer.write(message("t-2", "text" => "line one\nline two")) # newline inside a string
    expect(reader.read(timeout: 1)["payload"]).to eq("n" => 1)
    expect(reader.read(timeout: 1)["payload"]).to eq("text" => "line one\nline two")
  end

  it "reassembles a frame split across several writes" do
    line = JSON.generate(message("t-1", "big" => "x" * 200_000)) + "\n"
    thread = Thread.new do
      line.bytes.each_slice(7_000) { |slice| pipe[1].write(slice.pack("C*")) }
    end
    expect(reader.read(timeout: 5)["payload"]["big"].size).to eq(200_000)
    thread.join
  end

  it "times out instead of blocking when nothing arrives" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { reader.read(timeout: 0.2) }.to raise_error(Doubletrack::Protocol::ReadTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
  end

  it "reports EOF as Closed" do
    pipe[1].close
    expect { reader.read(timeout: 1) }.to raise_error(Doubletrack::Protocol::Closed)
  end

  it "reports EOF in the middle of a frame as Closed" do
    pipe[1].write('{"schema_version":1')
    pipe[1].close
    expect { reader.read(timeout: 1) }.to raise_error(Doubletrack::Protocol::Closed, /mid-frame/)
  end

  it "rejects invalid JSON" do
    pipe[1].write("not json\n")
    expect { reader.read(timeout: 1) }.to raise_error(Doubletrack::Protocol::ProtocolError, /not valid JSON/)
  end

  it "rejects frames over the size limit, with or without a newline" do
    small = Doubletrack::Protocol::Reader.new(pipe[0], max_frame_bytes: 1_000)
    pipe[1].write("x" * 2_000)
    expect { small.read(timeout: 1) }.to raise_error(Doubletrack::Protocol::FrameTooLarge)

    other = IO.pipe
    small2 = Doubletrack::Protocol::Reader.new(other[0], max_frame_bytes: 1_000)
    other[1].write(("y" * 1_500) + "\n")
    expect { small2.read(timeout: 1) }.to raise_error(Doubletrack::Protocol::FrameTooLarge)
  ensure
    other&.each(&:close)
  end

  it "refuses to write an invalid envelope" do
    expect { writer.write({"type" => "result"}) }.to raise_error(Doubletrack::Protocol::SchemaMismatch)
  end
end
