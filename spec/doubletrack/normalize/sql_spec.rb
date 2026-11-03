# frozen_string_literal: true

require "doubletrack/normalize/sql"

RSpec.describe Doubletrack::Normalize::Sql do
  def norm(sql) = described_class.call(sql)

  it "canonicalizes whitespace, identifier quoting and placeholders" do
    a = norm(%(INSERT INTO "orders" ("user_id", "total_cents")\n  VALUES (?, ?) RETURNING "id"))
    b = norm("INSERT INTO `orders` (`user_id`, `total_cents`) VALUES ($1, $2) RETURNING id")
    expect(a).to eq(b)
    expect(a["sql"]).to eq("INSERT INTO orders (user_id, total_cents) VALUES (?, ?) RETURNING id")
    expect(a["literals"]).to eq([])
  end

  it "moves inline literals out of the text, in order" do
    out = norm(%(UPDATE "orders" SET "status" = 'cancelled', "total_cents" = 1999, "note" = 'it''s', "x" = NULL WHERE "id" = 3))
    expect(out["sql"]).to eq("UPDATE orders SET status = ?, total_cents = ?, note = ?, x = ? WHERE id = ?")
    expect(out["literals"]).to eq(["cancelled", 1999, "it's", nil, 3])
  end

  it "does not treat digits inside identifiers as literals" do
    expect(norm(%(UPDATE "t1" SET "col2" = ?))["literals"]).to eq([])
  end

  it "keeps booleans and decimals as literals" do
    expect(norm("UPDATE t SET a = TRUE, b = 1.50, c = -2")["literals"]).to eq([true, 1.5, -2])
  end

  describe "properties" do
    random = Random.new(3)

    it "is idempotent on its own output, and sensitive to literal values" do
      100.times do
        value = random.rand(10_000)
        text = random.bytes(3).unpack1("H*")
        sql = %(UPDATE "orders"  SET "a" = #{value}, "b" = '#{text}' WHERE "id" = ?)
        once = norm(sql)
        expect(norm(once["sql"])["sql"]).to eq(once["sql"])
        expect(once["literals"]).to eq([value, text])
        expect(norm(sql.sub(value.to_s, (value + 1).to_s))).not_to eq(once)
      end
    end
  end
end
