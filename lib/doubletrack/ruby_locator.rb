# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "errors"

module Doubletrack
  # Which Ruby runs each side (ADR 0038, docs/design/rubies.md). Rubies are found among the
  # ones already installed, never installed.
  module RubyLocator
    module_function

    # @param spec [String] "auto", "current", a version, or a path to a ruby executable
    # @param app_root [String]
    # @return [Hash] {"path", "version", "source"} (+ "wanted" when auto fell back)
    def resolve(spec, app_root:, env: ENV)
      spec = spec.to_s.strip
      case spec
      when "", "current" then current
      when "auto"
        wanted = ruby_version_file(app_root)
        return current if wanted.nil? || wanted == RUBY_VERSION

        path = find(wanted, env: env)
        path ? {"path" => path, "version" => wanted, "source" => ".ruby-version"} : current.merge("wanted" => wanted)
      else
        if spec.include?("/")
          version = probe(spec)
          raise ConfigError, "#{spec} is not a working ruby executable" unless version

          {"path" => spec, "version" => version, "source" => "config"}
        else
          version = normalize(spec)
          return current.merge("source" => "config") if version == RUBY_VERSION

          path = find(version, env: env)
          raise ConfigError, "Ruby #{version} isn't installed (looked in #{candidates(version, env).map { |c| File.dirname(c, 2) }.join(", ")}); install it, or set ruby/next_ruby to a path" unless path

          {"path" => path, "version" => version, "source" => "config"}
        end
      end
    end

    # @return [String, nil] the path of an installed ruby reporting this version
    def find(version, env: ENV)
      version = normalize(version)
      candidates(version, env).find { |path| File.executable?(path) && probe(path) == version }
    end

    def current = {"path" => RbConfig.ruby, "version" => RUBY_VERSION, "source" => "current"}

    def candidates(version, env)
      home = env["HOME"] || Dir.home
      [
        File.join(env["RBENV_ROOT"] || File.join(home, ".rbenv"), "versions", version),
        File.join(env["ASDF_DATA_DIR"] || File.join(home, ".asdf"), "installs", "ruby", version),
        File.join(home, ".local", "share", "mise", "installs", "ruby", version),
        File.join(home, ".rubies", "ruby-#{version}"),
        File.join("/opt/rubies", "ruby-#{version}"),
        File.join(home, ".rvm", "rubies", "ruby-#{version}"),
        env["RUNNER_TOOL_CACHE"] && File.join(env["RUNNER_TOOL_CACHE"], "Ruby", version, "x64")
      ].compact.map { |dir| File.join(dir, "bin", "ruby") }
    end

    # Another Ruby must not see this process's Bundler (`bundle exec` puts its lib on RUBYLIB):
    # loading one Ruby's Bundler into another breaks it.
    PROBE_ENV = {"RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil, "GEM_ROOT" => nil,
                 "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil}.freeze

    def probe(path)
      out, _err, status = Open3.capture3(PROBE_ENV, path, "-e", "print RUBY_VERSION")
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def ruby_version_file(app_root)
      path = File.join(app_root, ".ruby-version")
      return nil unless File.exist?(path)

      value = normalize(File.read(path).lines.first.to_s)
      value.empty? ? nil : value
    end

    def normalize(text) = text.to_s.strip.sub(/\Aruby-/, "")
  end
end
