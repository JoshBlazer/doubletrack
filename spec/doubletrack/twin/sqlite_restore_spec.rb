# frozen_string_literal: true

require "sqlite3"
require "tmpdir"
require "doubletrack/twin/sqlite_restore"

# Apps may hold their own SQLite connections outside Active Record's pool: once-campfire
# runs a WAL-checkpoint thread that opens the database file every 250 ms. Deleting and
# copying the file under such a connection (the old restore) let a session's first
# queries see an empty schema ("no such table: bans") on a random twin. Restoring through
# SQLite's online backup API keeps every connection consistent (ADR 0029).
RSpec.describe Doubletrack::Twin::SqliteRestore do
  around { |ex| Dir.mktmpdir { |dir| @dir = dir and ex.run } }

  def template(rows)
    path = File.join(@dir, "template-#{rows}.sqlite3")
    SQLite3::Database.new(path) do |db|
      db.execute("CREATE TABLE bans (id INTEGER PRIMARY KEY, ip TEXT)")
      rows.times { |i| db.execute("INSERT INTO bans (ip) VALUES (?)", ["10.0.0.#{i}"]) }
    end
    path
  end

  let(:database) { File.join(@dir, "work.sqlite3") }

  it "creates the working database from the template" do
    described_class.call(template(2), database)
    expect(SQLite3::Database.new(database).get_first_value("SELECT COUNT(*) FROM bans")).to eq(2)
  end

  it "replaces the content in place, so a connection the app keeps open sees the new content" do
    described_class.call(template(1), database)
    held = SQLite3::Database.new(database)
    held.execute("PRAGMA journal_mode = WAL")
    expect(held.get_first_value("SELECT COUNT(*) FROM bans")).to eq(1)
    described_class.call(template(3), database)
    expect(held.get_first_value("SELECT COUNT(*) FROM bans")).to eq(3)
  ensure
    held&.close
  end

  it "never shows another connection an empty schema while a contender keeps opening the file" do
    a = template(1)
    b = template(2)
    described_class.call(a, database)
    stop = false
    errors = Queue.new
    contender = Thread.new do
      until stop
        begin
          SQLite3::Database.new(database) do |db|
            db.busy_timeout = 1_000
            db.execute("PRAGMA journal_mode = WAL")
            db.execute("PRAGMA wal_checkpoint(PASSIVE)")
          end
        rescue SQLite3::Exception => e
          errors << e
        end
      end
    end
    50.times do |i|
      described_class.call(i.even? ? b : a, database)
      SQLite3::Database.new(database) do |db|
        db.busy_timeout = 1_000
        expect(db.get_first_value("SELECT COUNT(*) FROM bans")).to eq(i.even? ? 2 : 1)
      end
    end
    stop = true
    contender.join
    expect(errors.size).to eq(0), -> { errors.pop.full_message }
  end

  it "raises for a missing template" do
    expect { described_class.call(File.join(@dir, "nope.sqlite3"), database) }.to raise_error(ArgumentError, /not found/)
  end
end
