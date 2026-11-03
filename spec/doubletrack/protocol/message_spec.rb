# frozen_string_literal: true

require "doubletrack/protocol"

RSpec.describe Doubletrack::Protocol::Message do
  let(:valid) do
    {"schema_version" => 1, "id" => "c-000001", "type" => "run_session", "reply_to" => nil, "payload" => {}}
  end

  describe ".build" do
    it "produces a valid envelope with the current schema version" do
      message = described_class.build(id: "c-000001", type: "shutdown")
      expect(message).to eq(valid.merge("type" => "shutdown"))
    end

    it "rejects unknown types at construction time" do
      expect { described_class.build(id: "x", type: "explode") }
        .to raise_error(Doubletrack::Protocol::UnknownType)
    end
  end

  describe ".validate!" do
    it "accepts a valid envelope and ignores unknown extra fields" do
      expect(described_class.validate!(valid.merge("future_field" => 1))).to include("id" => "c-000001")
    end

    it "rejects a different schema_version" do
      expect { described_class.validate!(valid.merge("schema_version" => 2)) }
        .to raise_error(Doubletrack::Protocol::SchemaMismatch, /schema_version 2/)
    end

    it "rejects a missing schema_version" do
      expect { described_class.validate!(valid.except("schema_version")) }
        .to raise_error(Doubletrack::Protocol::SchemaMismatch)
    end

    it "rejects non-object messages" do
      expect { described_class.validate!([1, 2]) }.to raise_error(Doubletrack::Protocol::ProtocolError)
    end

    it "rejects an empty or missing id" do
      expect { described_class.validate!(valid.merge("id" => "")) }.to raise_error(Doubletrack::Protocol::ProtocolError)
      expect { described_class.validate!(valid.except("id")) }.to raise_error(Doubletrack::Protocol::ProtocolError)
    end

    it "rejects unknown types" do
      expect { described_class.validate!(valid.merge("type" => "nope")) }
        .to raise_error(Doubletrack::Protocol::UnknownType)
    end

    it "rejects a non-object payload and a non-string reply_to" do
      expect { described_class.validate!(valid.merge("payload" => "x")) }.to raise_error(Doubletrack::Protocol::ProtocolError)
      expect { described_class.validate!(valid.merge("reply_to" => 7)) }.to raise_error(Doubletrack::Protocol::ProtocolError)
    end
  end

  describe ".error" do
    it "includes exception class and at most 20 backtrace frames" do
      exception = RuntimeError.new("boom")
      exception.set_backtrace(Array.new(50) { |i| "frame#{i}" })
      message = described_class.error(id: "t-1", code: "session_failed", message: "boom", reply_to: "c-1", exception: exception)
      expect(message["payload"]).to include("code" => "session_failed", "exception_class" => "RuntimeError")
      expect(message["payload"]["backtrace"].size).to eq(20)
      expect(message["reply_to"]).to eq("c-1")
    end
  end

  describe "body encoding" do
    it "keeps valid UTF-8 as text" do
      expect(described_class.encode_body("héllo")).to eq("encoding" => "utf-8", "data" => "héllo")
    end

    it "base64-encodes invalid UTF-8 and round-trips the exact bytes" do
      bytes = "\xFF\x00\xFEpng".b
      encoded = described_class.encode_body(bytes)
      expect(encoded["encoding"]).to eq("base64")
      expect(described_class.decode_body(encoded)).to eq(bytes)
    end

    it "round-trips random byte strings (property)" do
      random = Random.new(1234)
      200.times do
        bytes = random.bytes(random.rand(0..64))
        decoded = described_class.decode_body(described_class.encode_body(bytes))
        expect(decoded.b).to eq(bytes.b)
      end
    end
  end
end
