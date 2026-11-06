# frozen_string_literal: true

module Doubletrack
  module Twin
    # Database-level statements for PostgreSQL twins (ADR 0037), on a separate connection
    # to the `postgres` maintenance database, never through the app's pool.
    class PostgresAdmin
      # @param params [Hash] {"host", "port", "username", "password"}
      def initialize(params)
        require "pg"
        @params = params
      end

      def ensure_database!(name)
        with_connection do |c|
          check_version!(c)
          exists = c.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive?
          c.exec("CREATE DATABASE #{c.quote_ident(name)}") unless exists
        end
      end

      # A fresh, empty database (dropping one left over from an earlier run).
      def recreate(name)
        with_connection do |c|
          c.exec("DROP DATABASE IF EXISTS #{c.quote_ident(name)} WITH (FORCE)")
          c.exec("CREATE DATABASE #{c.quote_ident(name)}")
        end
      end

      # Replaces `name` with a copy of `template`. FORCE ends connections the app's own
      # threads hold on `name` (RISKS R18).
      def copy(template, name)
        with_connection do |c|
          c.exec("DROP DATABASE IF EXISTS #{c.quote_ident(name)} WITH (FORCE)")
          c.exec("CREATE DATABASE #{c.quote_ident(name)} TEMPLATE #{c.quote_ident(template)}")
        end
      end

      def exists?(name)
        with_connection { |c| c.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive? }
      end

      def size(name)
        with_connection { |c| c.exec_params("SELECT pg_database_size($1)", [name]).getvalue(0, 0).to_i }
      end

      def drop(*names)
        with_connection do |c|
          names.each { |n| c.exec("DROP DATABASE IF EXISTS #{c.quote_ident(n)} WITH (FORCE)") }
        end
      end

      # Databases named with the given prefix (leftovers of crashed runs).
      def list(prefix)
        with_connection do |c|
          c.exec_params("SELECT datname FROM pg_database WHERE datname LIKE $1 ORDER BY datname", ["#{prefix}%"]).column_values(0)
        end
      end

      private

      def check_version!(connection)
        version = connection.server_version
        return if version >= Database::MIN_POSTGRES

        raise ArgumentError, "PostgreSQL #{version / 10_000}.#{version % 10_000 / 100} is too old: Doubletrack needs 13 or newer (ADR 0037)"
      end

      def with_connection
        connection = PG.connect(host: @params["host"], port: @params["port"], user: @params["username"],
          password: @params["password"], dbname: "postgres")
        connection.set_notice_processor { |_| } # NOTICE: database "x" does not exist, skipping
        yield connection
      ensure
        connection&.close
      end
    end
  end
end
