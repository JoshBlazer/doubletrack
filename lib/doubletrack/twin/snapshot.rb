# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "sqlite_restore"
require_relative "database"

module Doubletrack
  module Twin
    # SQLite snapshots (ADR 0004, docs/design/replay.md#snapshots). Runs inside a booted
    # twin; uses ActiveRecord. One twin builds the template; every twin restores it.
    class Snapshot
      SIDECARS = %w[-wal -shm -journal].freeze

      # @param database_path [String] this twin's private working database
      # @param app_root [String]
      def initialize(database_path:, app_root:)
        @database_path = database_path
        @app_root = app_root
      end

      FIXTURE_DIRS = %w[test/fixtures spec/fixtures].freeze

      # Builds the template: empty database, db/schema.rb, optional db/seeds.rb, optional
      # test fixtures (ADR 0026), then VACUUM INTO. The caller seeds rand around this.
      # @return [Hash] {"template_path", "bytes", "sha256", "tables"}
      def build(template_path, seeds: false, fixtures: false, seed: 0)
        check_supported!
        return postgres.build(template_path, seeds: seeds, fixtures: fixtures, seed: seed) if postgres?

        disconnect
        remove_database
        load_contents(seeds: seeds, fixtures: fixtures)

        FileUtils.mkdir_p(File.dirname(template_path))
        FileUtils.rm_f(template_path)
        tables = ActiveRecord::Base.connection_pool.with_connection do |c|
          c.execute("VACUUM INTO #{c.quote(template_path)}")
          c.tables.sort.to_h { |t| [t, c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name(t)}").to_i] }
        end
        disconnect
        {
          "template_path" => template_path,
          "bytes" => File.size(template_path),
          "sha256" => Digest::SHA256.file(template_path).hexdigest,
          "tables" => tables
        }
      end

      # Replaces the working database's content with the template's, in place, through
      # SQLite's backup API (ADR 0029): the app may hold connections of its own on the
      # file, which deleting and copying it would leave inconsistent. The next Active
      # Record query reconnects.
      def restore(template_path)
        return postgres.restore(template_path) if postgres?

        disconnect
        SqliteRestore.call(template_path, @database_path)
      end

      # Drops what this twin created on the database server (PostgreSQL); SQLite files go
      # with the run's work directory.
      def cleanup
        postgres.cleanup if postgres?
      end

      # db/schema.rb, then optionally db/seeds.rb and the test fixtures, into the current
      # connection.
      def load_contents(seeds:, fixtures:)
        schema = File.join(@app_root, "db", "schema.rb")
        raise ArgumentError, "db/schema.rb not found (structure.sql apps are not supported yet)" unless File.exist?(schema)

        ActiveRecord::Schema.verbose = false
        load schema
        if seeds
          seeds_file = File.join(@app_root, "db", "seeds.rb")
          load seeds_file if File.exist?(seeds_file)
        end
        load_fixtures if fixtures
      end

      private

      # Every *.yml under test/fixtures (or spec/fixtures), as the app's tests load them
      # with `fixtures :all`. Fixture ids are deterministic, so captured ids resolve.
      def load_fixtures
        dir = FIXTURE_DIRS.map { |d| File.join(@app_root, d) }.find { |d| File.directory?(d) }
        raise ArgumentError, "a fixtures snapshot needs test/fixtures or spec/fixtures (ADR 0026)" unless dir

        names = Dir.glob(File.join(dir, "**", "*.yml")).map { |f| f.delete_prefix("#{dir}/").delete_suffix(".yml") }.sort
        return if names.empty?

        require "active_record/fixtures"
        ActiveRecord::FixtureSet.reset_cache
        ActiveRecord::FixtureSet.create_fixtures(dir, names)
      end

      def check_supported!
        configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env.to_s)
        raise ArgumentError, "multiple databases are not supported yet (RISKS R7)" if configs.size > 1

        adapter = ActiveRecord::Base.connection_db_config.adapter.to_s
        return if adapter.start_with?("sqlite") || (postgres? && adapter.start_with?("postg"))

        raise ArgumentError, "only SQLite and PostgreSQL are supported (adapter: #{adapter})"
      end

      def postgres? = !Database.postgres.nil?

      def postgres
        require_relative "postgres_snapshot"
        @postgres ||= PostgresSnapshot.new(params: Database.postgres, loader: method(:load_contents))
      end

      def disconnect
        ActiveRecord::Base.connection_pool.disconnect!
      end

      def remove_database
        ([@database_path] + SIDECARS.map { |s| @database_path + s }).each { |path| FileUtils.rm_f(path) }
      end
    end
  end
end
