# frozen_string_literal: true

require "date"
require "json"
require "doubletrack/recorder/jsonable"

RSpec.describe Doubletrack::Recorder::Jsonable do
  def convert(value) = described_class.call(value)

  it "passes JSON primitives through" do
    expect(convert([nil, true, false, 1, 1.5, "x"])).to eq([nil, true, false, 1, 1.5, "x"])
  end

  it "formats times as UTC ISO 8601 with microseconds" do
    expect(convert(Time.new(2026, 11, 3, 1, 2, 3.25, "+01:00"))).to eq("2026-11-03T00:02:03.250000Z")
    expect(convert(Date.new(2026, 11, 3))).to eq("2026-11-03")
  end

  # Regression: Time#utc converts in place; the recorder must never mutate app objects.
  it "does not mutate the Time it converts" do
    time = Time.new(2026, 11, 3, 1, 2, 3, "+01:00")
    convert(time)
    expect(time.utc_offset).to eq(3600)
  end

  # BigDecimal (exact decimal string) is covered by the integration specs inside Rails;
  # bigdecimal is not a default gem on Ruby 3.4+, so it is not loaded here.
  it "stringifies keys and symbols" do
    expect(convert({:a => 1, "b" => :c})).to eq("a" => 1, "b" => "c")
  end

  it "hashes binary strings instead of embedding them" do
    expect(convert("\xFF\x00".b)).to eq("binary_sha256" => Digest::SHA256.hexdigest("\xFF\x00".b))
  end

  # Regression: found by the property test below; binary hash keys broke JSON.generate.
  it "converts binary hash keys to text keys" do
    converted = convert({"\xD4\x01".b => 1})
    expect(converted).to eq("binary_sha256:#{Digest::SHA256.hexdigest("\xD4\x01".b)}" => 1)
    expect { JSON.generate(converted) }.not_to raise_error
  end

  it "turns non-finite floats into strings and unknown objects into inspect strings" do
    expect(convert(Float::INFINITY)).to eq("Infinity")
    expect(convert(Object.new)).to match(/\A#<Object/)
  end

  # Exception messages, SQL text, header values and cache keys reach the trace without
  # going through .call; one invalid byte there used to abort the whole run.
  it "scrubs invalid UTF-8 anywhere in a tree so the trace can always be sent" do
    bad = "unexpected token at '\xFF'".dup.force_encoding(Encoding::UTF_8)
    tree = {"exception" => {"message" => bad}, "sql" => ["a", {"k" => bad}], bad => 1, "n" => 2}
    clean = described_class.scrub(tree)
    expect { JSON.generate(clean) }.not_to raise_error
    expect(clean.dig("exception", "message")).to eq("unexpected token at '\uFFFD'")
    expect(clean["n"]).to eq(2)
    expect(described_class.scrub("ok")).to eq("ok")
  end

  it "always produces JSON-encodable output (property)" do
    random = Random.new(42)
    atoms = [-> { random.rand(-1000..1000) }, -> { random.rand }, -> { random.bytes(4) }, -> { :sym },
      -> { Time.at(random.rand(2**31)) }, -> {}, -> { Object.new }, -> { Float::NAN }]
    gen = ->(depth) {
      case (depth > 3) ? 0 : random.rand(3)
      when 0 then atoms.sample(random: random).call
      when 1 then Array.new(random.rand(4)) { gen.call(depth + 1) }
      else Array.new(random.rand(4)) { [random.bytes(3), gen.call(depth + 1)] }.to_h
      end
    }
    300.times do
      value = gen.call(0)
      converted = convert(value)
      expect { JSON.generate(converted) }.not_to raise_error
      expect(convert(converted)).to eq(converted) # idempotent
    end
  end
end
