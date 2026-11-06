# frozen_string_literal: true

require "doubletrack/twin/database"

RSpec.describe Doubletrack::Twin::Database do
  describe ".connection_for" do
    it "uses the app's DATABASE_URL first, as Rails does for the test environment" do
      c = described_class.connection_for({"adapter" => "sqlite3", "database" => "x"}, "postgres://u:p@db:5433/app_test")
      expect(c).to eq("adapter" => "postgresql", "host" => "db", "port" => 5433, "username" => "u", "password" => "p", "database" => "app_test")
    end

    it "reads host, port, username and password from the test config, or its url" do
      expect(described_class.connection_for({"adapter" => "postgresql", "host" => "localhost", "username" => "me", "database" => "t"}, nil))
        .to eq("adapter" => "postgresql", "host" => "localhost", "port" => nil, "username" => "me", "password" => nil, "database" => "t")
      expect(described_class.connection_for({"adapter" => "postgresql", "url" => "postgresql://a:b%40c@h/d"}, nil))
        .to include("adapter" => "postgresql", "host" => "h", "username" => "a", "password" => "b@c", "database" => "d")
    end

    it "keeps SQLite and unknown configs as they are" do
      expect(described_class.connection_for({"adapter" => "sqlite3", "database" => "db/t.sqlite3"}, nil)).to include("adapter" => "sqlite3")
      expect(described_class.connection_for(nil, nil)).to be_nil
    end
  end

  describe ".test_config" do
    it "picks the primary database of a multi-database test config and refuses several" do
      expect(described_class.test_config("test" => {"primary" => {"adapter" => "postgresql", "database" => "a"}})).to include("database" => "a")
      expect(described_class.test_config("test" => {"adapter" => "sqlite3", "database" => "b"})).to include("database" => "b")
      expect { described_class.test_config("test" => {"primary" => {"adapter" => "postgresql"}, "cache" => {"adapter" => "postgresql"}}) }
        .to raise_error(ArgumentError, /multiple databases/)
    end
  end

  describe ".database_name" do
    it "is private to the run and role, a valid identifier, and under 63 characters" do
      a = described_class.database_name("/tmp/run-1/work", "control_a")
      expect(a).to match(/\Adt_\h{10}_control_a\z/)
      expect(described_class.database_name("/tmp/run-1/work", "control_a_prime")).not_to eq(a)
      expect(described_class.database_name("/tmp/run-2/work", "control_a")).not_to eq(a)
      expect(described_class.template_name("/tmp/run-1/work", "/tmp/run-1/work/template-default.sqlite3").length).to be <= 63
    end
  end

  describe ".url" do
    it "builds a postgresql URL with escaped credentials and the private database" do
      c = {"adapter" => "postgresql", "host" => "db", "port" => 5432, "username" => "u s", "password" => "p@ss/w", "database" => "x"}
      expect(described_class.url(c, "dt_abc_control_a")).to eq("postgresql://u%20s:p%40ss%2Fw@db:5432/dt_abc_control_a")
      expect(described_class.url({"adapter" => "postgresql"}, "dt_x")).to eq("postgresql:///dt_x")
    end
  end
end
