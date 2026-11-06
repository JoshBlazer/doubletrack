# frozen_string_literal: true

require "digest"
require "uri"

module Doubletrack
  module Twin
    # Which database a twin uses (docs/design/postgresql.md, ADR 0037). Runs inside the
    # twin after config/application.rb loads and before the environment does. SQLite apps
    # keep the coordinator's DATABASE_URL (a file in the run's work directory); PostgreSQL
    # apps get a private database on the server their test configuration names.
    module Database
      POSTGRES_ADAPTERS = %w[postgresql postgres postgis].freeze
      MIN_POSTGRES = 130_000 # DROP DATABASE ... WITH (FORCE)

      class << self
        # Connection parameters of a PostgreSQL twin ({"host", "port", "username", "password", "database"}), or nil.
        attr_reader :postgres
      end

      module_function

      # @param role [String]
      # @param work_dir [String]
      # @param app_database_url [String, nil] the DATABASE_URL the coordinator was started with
      # @return [Hash] {"adapter", "name"} for hello
      def configure!(role:, work_dir:, app_database_url:)
        raw = Rails.application.config.database_configuration
        connection = with_env("DATABASE_URL" => app_database_url) { connection_for(test_config(raw), app_database_url) }
        unless connection && POSTGRES_ADAPTERS.include?(connection["adapter"].to_s)
          return {"adapter" => connection ? connection["adapter"].to_s : "sqlite3", "name" => ENV["DATABASE_URL"].to_s.sub(%r{\Asqlite3:}, "")}
        end

        name = database_name(work_dir, role)
        @postgres = connection.merge("database" => name, "work_dir" => work_dir)
        ENV["DATABASE_URL"] = url(connection, name)
        require_relative "postgres_admin"
        PostgresAdmin.new(@postgres).ensure_database!(name)
        {"adapter" => "postgresql", "name" => name}
      end

      # The test environment's primary database configuration (YAML already evaluated).
      def test_config(raw)
        test = raw.is_a?(Hash) ? raw["test"] : nil
        return nil unless test.is_a?(Hash)
        return test if test.key?("adapter") || test.key?("url") || test.key?("database")

        configs = test.select { |_name, value| value.is_a?(Hash) }
        raise ArgumentError, "multiple databases are not supported yet (RISKS R7)" if configs.size > 1

        configs.values.first
      end

      # @return [Hash, nil] {"adapter", "host", "port", "username", "password", "database"}
      def connection_for(config, app_database_url)
        source = app_database_url.to_s.empty? ? config : {"url" => app_database_url}
        return nil unless source.is_a?(Hash)

        if source["url"].to_s.match?(%r{\A[a-z0-9+]+://}i)
          uri = URI.parse(source["url"])
          scheme = uri.scheme.to_s
          return {"adapter" => POSTGRES_ADAPTERS.include?(scheme) ? "postgresql" : scheme, "host" => blank(uri.host), "port" => uri.port,
                  "username" => decode(uri.user), "password" => decode(uri.password), "database" => blank(uri.path.to_s.delete_prefix("/"))}
        end
        adapter = source["adapter"].to_s
        return source.slice("adapter", "database") unless POSTGRES_ADAPTERS.include?(adapter)

        {"adapter" => "postgresql", "host" => source["host"], "port" => source["port"]&.to_i,
         "username" => source["username"] || source["user"], "password" => source["password"], "database" => source["database"]}
      end

      # "dt_<10 hex>_<role>": private to the run (work directory) and the twin.
      def database_name(work_dir, role)
        "dt_#{Digest::SHA256.hexdigest(work_dir.to_s)[0, 10]}_#{role.to_s.gsub(/[^a-z0-9_]/, "_")}"
      end

      def template_name(work_dir, template_path)
        "dt_#{Digest::SHA256.hexdigest(work_dir.to_s)[0, 10]}_t_#{Digest::SHA256.hexdigest(template_path.to_s)[0, 12]}"
      end

      def url(connection, name)
        userinfo = if connection["username"]
          escape(connection["username"]) + (connection["password"] ? ":#{escape(connection["password"])}" : "") + "@"
        else
          ""
        end
        host = connection["host"].to_s
        port = connection["port"] ? ":#{connection["port"]}" : ""
        "postgresql://#{userinfo}#{host}#{port}/#{name}"
      end

      def escape(text) = URI.encode_www_form_component(text.to_s).gsub("+", "%20")

      def decode(text) = text && URI.decode_www_form_component(text)

      def blank(text) = (text.nil? || text.empty?) ? nil : text

      def with_env(vars)
        saved = vars.keys.to_h { |k| [k, ENV[k]] }
        vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
        yield
      ensure
        saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      end
    end
  end
end
