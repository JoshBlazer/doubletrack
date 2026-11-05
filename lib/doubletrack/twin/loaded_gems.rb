# frozen_string_literal: true

module Doubletrack
  module Twin
    # The gems a twin loaded, for `hello` (ADR 0032): where each one's source is, and for
    # git sources the revision, Bundler's clone and the remote (credentials removed).
    module LoadedGems
      module_function

      # @return [Array<Hash>] {"name", "version", "path", "revision", "git_cache", "remote"}, by name
      def call(specs = Gem.loaded_specs.values)
        specs.map { |spec| entry(spec) }.sort_by { |g| g["name"] }
      rescue
        []
      end

      def entry(spec)
        source = spec.respond_to?(:source) ? spec.source : nil
        git = source.respond_to?(:revision) && source.respond_to?(:cache_path)
        {
          "name" => spec.name,
          "version" => spec.version.to_s,
          "path" => spec.full_gem_path,
          "revision" => git ? safe { source.revision } : nil,
          "git_cache" => git ? safe { source.cache_path.to_s } : nil,
          "remote" => git ? safe { without_credentials(source.uri.to_s) } : nil
        }
      end

      # "https://user:token@github.com/x/y.git" → "https://github.com/x/y.git"
      def without_credentials(uri)
        uri.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, "\\1")
      end

      def safe
        yield
      rescue
        nil
      end
    end
  end
end
