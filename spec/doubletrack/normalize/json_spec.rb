# frozen_string_literal: true

require "json"
require "doubletrack/normalize/json"

RSpec.describe Doubletrack::Normalize::Json do
  def norm(text) = described_class.call(text)

  it "sorts keys recursively and keeps array order" do
    expect(norm('{"b":1,"a":{"d":[3,1],"c":2}}')).to eq({"a" => {"c" => 2, "d" => [3, 1]}, "b" => 1})
    expect(norm('{"b":1,"a":2}').keys).to eq(%w[a b])
  end

  it "canonicalizes number spelling but keeps integer vs float" do
    expect(norm('{"x":1.50}')).to eq(norm('{"x":1.5}'))
    expect(norm('{"x":1e2}')).to eq(norm('{"x":100.0}'))
    expect(JSON.generate(norm(%({"x":1})))).not_to eq(JSON.generate(norm(%({"x":1.0})))) # Ruby 1 == 1.0, so compare serialized
  end

  it "returns nil for invalid JSON" do
    expect(norm("{nope")).to be_nil
  end

  describe "properties" do
    random = Random.new(7)
    gen = ->(depth) {
      case (depth > 3) ? random.rand(3) : random.rand(6)
      when 0 then random.rand(-1000..1000)
      when 1 then random.rand.round(3)
      when 2 then ["x", "y", "", "ü", nil, true][random.rand(6)]
      when 3 then Array.new(random.rand(4)) { gen.call(depth + 1) }
      else Array.new(random.rand(4)) { ["k#{random.rand(6)}", gen.call(depth + 1)] }.to_h
      end
    }
    shuffle = ->(v) {
      case v
      when Hash then v.to_a.shuffle(random: random).to_h { |k, x| [k, shuffle.call(x)] }
      when Array then v.map { |x| shuffle.call(x) }
      else v
      end
    }

    it "is idempotent and invariant under key order and whitespace" do
      200.times do
        value = gen.call(0)
        once = norm(JSON.generate(value))
        expect(norm(JSON.generate(once))).to eq(once)
        expect(norm(JSON.pretty_generate(shuffle.call(value)))).to eq(once)
      end
    end

    it "still sees a changed leaf" do
      expect(norm('{"a":{"b":[1,2]}}')).not_to eq(norm('{"a":{"b":[1,3]}}'))
    end
  end
end
