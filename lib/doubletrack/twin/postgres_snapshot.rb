# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "database"
require_relative "postgres_admin"

module Doubletrack
  module Twin
    # PostgreSQL snapshots (ADR 0037, docs/design/postgresql.md): the template is a
    # database built from db/schema.rb (+ seeds, + fixtures); a session restores it with
    # DROP DATABASE ... WITH (FORCE) and CREATE DATABASE ... TEMPLATE. The file at
    # template_path is a small recipe, so reproductions can rebuild the template.
    class PostgresSnapshot
      RECIPE_VERSION = 1

      # @param params [Hash] Database.postgres
      # @param loader [#call] (seeds:, fixtures:) loads schema, seeds and fixtures into the current connection
      def initialize(params:, loader:)
        @params = params
        @own = params.fetch("database")
        @work_dir = params.fetch("work_dir")
        @loader = loader
        @admin = PostgresAdmin.new(params)
        @built = []
      end

      # @return [Hash] {"template_path", "adapter", "template", "bytes", "sha256", "tables"}
      def build(template_path, seeds: false, fixtures: false, seed: 0)
        name = Database.template_name(@work_dir, template_path)
        tables = build_template(name, seeds: seeds, fixtures: fixtures)
        FileUtils.mkdir_p(File.dirname(template_path))
        File.write(template_path, JSON.generate({"doubletrack_snapshot" => RECIPE_VERSION, "adapter" => "postgresql",
                                                 "seed" => seed, "seeds" => seeds, "fixtures" => fixtures}) + "\n")
        {
          "template_path" => template_path,
          "adapter" => "postgresql",
          "template" => name,
          "bytes" => @admin.size(name),
          "sha256" => Digest::SHA256.hexdigest(JSON.generate(tables)),
          "tables" => tables
        }
      end

      # Restores the template named by template_path; builds it first from the recipe when
      # this twin hasn't (a reproduction, in its own process).
      def restore(template_path)
        name = Database.template_name(@work_dir, template_path)
        unless @built.include?(name) || @admin.exists?(name)
          recipe = self.class.recipe(template_path)
          Kernel.srand(Integer(recipe.fetch("seed", 0)))
          build_template(name, seeds: recipe["seeds"] == true, fixtures: recipe["fixtures"] == true)
        end
        ActiveRecord::Base.connection_pool.disconnect!
        @admin.copy(name, @own)
      end

      # Drops this twin's database and the templates it built (at shutdown).
      def cleanup
        ActiveRecord::Base.connection_pool.disconnect!
        @admin.drop(@own, *@built)
        warn "doubletrack twin: dropped databases #{([@own] + @built).join(", ")}"
      end

      # @return [Hash, nil] the recipe in a snapshot file, or nil for a SQLite file
      def self.recipe(path)
        return nil unless File.exist?(path) && File.size(path) < 4096

        data = JSON.parse(File.read(path))
        (data.is_a?(Hash) && data["adapter"] == "postgresql") ? data : nil
      rescue JSON::ParserError, ArgumentError
        nil
      end

      private

      def build_template(name, seeds:, fixtures:)
        @admin.recreate(name)
        @built << name unless @built.include?(name)
        original = ActiveRecord::Base.connection_db_config.configuration_hash
        ActiveRecord::Base.connection_pool.disconnect!
        ActiveRecord::Base.establish_connection(original.merge(database: name, url: Database.url(@params, name)))
        begin
          @loader.call(seeds: seeds, fixtures: fixtures)
          ActiveRecord::Base.connection_pool.with_connection do |c|
            c.tables.sort.to_h { |t| [t, c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name(t)}").to_i] }
          end
        ensure
          ActiveRecord::Base.connection_pool.disconnect!
          ActiveRecord::Base.establish_connection(original)
        end
      end
    end
  end
end
