# frozen_string_literal: true

require "yaml"
require_relative "errors"

module Doubletrack
  # Run configuration: `doubletrack.yml` in the app root (optional), overridden by
  # command-line options. Unknown keys are errors, so a typo can't silently change a run.
  #
  #   gemfile: Gemfile                 # control A and A′ (current Rails)
  #   next_gemfile: Gemfile.next       # candidate B (next Rails)
  #   sessions: doubletrack/sessions   # directory of *.jsonl (docs/formats/session.md)
  #   seeds: false                     # load db/seeds.rb into the snapshot template
  #   perform_jobs: true               # ADR 0014
  #   ignored_columns: []              # bind columns never compared (e.g. updated_at)
  #   ignored_headers: []              # response headers never compared
  #   boot_timeout: 120                # seconds
  #   request_timeout: 120             # seconds per session reply
  #   baseline: doubletrack.baseline.yml   # accepted findings (ADR 0024)
  #   repro_framework: auto            # auto, rspec or minitest (ADR 0022)
  #   http_stubs: doubletrack/http_stubs.json  # stubs added to captured sessions (M5)
  #   ruby: auto                       # Ruby for control A and A′, and capture (ADR 0038)
  #   next_ruby: null                  # Ruby for candidate B (default: same as ruby)
  class Config
    FILE = "doubletrack.yml"
    DEFAULTS = {
      "gemfile" => "Gemfile",
      "next_gemfile" => "Gemfile.next",
      "sessions" => "doubletrack/sessions",
      "seeds" => false,
      "perform_jobs" => true,
      "ignored_columns" => [],
      "ignored_headers" => [],
      "boot_timeout" => 120,
      "request_timeout" => 120,
      "baseline" => "doubletrack.baseline.yml",
      "repro_framework" => "auto",
      "http_stubs" => "doubletrack/http_stubs.json",
      "ruby" => "auto",
      "next_ruby" => nil
    }.freeze

    attr_reader :app_root, :values

    # @param app_root [String]
    # @param overrides [Hash{String=>Object}] from the command line (nil values ignored)
    # @return [Config]
    def self.load(app_root, overrides = {})
      path = File.join(app_root, FILE)
      file = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      raise ConfigError, "#{path}: expected a mapping" unless file.is_a?(Hash)

      new(app_root, file.merge(overrides.compact))
    rescue Psych::Exception => e # syntax errors, and values safe_load refuses (dates, aliases)
      raise ConfigError, "#{path}: #{e.message}"
    end

    def initialize(app_root, values)
      @app_root = File.expand_path(app_root)
      unknown = values.keys - DEFAULTS.keys
      raise ConfigError, "unknown #{FILE} key #{unknown.first.inspect} (allowed: #{DEFAULTS.keys.join(", ")})" unless unknown.empty?

      @values = DEFAULTS.merge(values)
      %w[seeds perform_jobs].each do |key|
        raise ConfigError, "#{key} must be true or false" unless [true, false].include?(@values[key])
      end
      %w[ignored_columns ignored_headers].each do |key|
        raise ConfigError, "#{key} must be a list of strings" unless @values[key].is_a?(Array) && @values[key].all?(String)
      end
      %w[boot_timeout request_timeout].each do |key|
        value = @values[key]
        unless value.is_a?(Numeric) && value.positive? && value.finite?
          raise ConfigError, "#{key} must be a positive number of seconds (got #{value.inspect})"
        end
      end
      %w[gemfile next_gemfile sessions baseline http_stubs].each do |key|
        raise ConfigError, "#{key} must be a path (got #{@values[key].inspect})" unless @values[key].is_a?(String) && !@values[key].empty?
      end
      raise ConfigError, "ruby must be auto, current, a version or a path" unless @values["ruby"].is_a?(String) && !@values["ruby"].empty?
      next_ruby = @values["next_ruby"]
      if !next_ruby.nil? && (!next_ruby.is_a?(String) || next_ruby.empty?)
        raise ConfigError, "next_ruby must be auto, current, a version or a path"
      end
      unless %w[auto rspec minitest].include?(@values["repro_framework"])
        raise ConfigError, "repro_framework must be auto, rspec or minitest (got #{@values["repro_framework"].inspect})"
      end
      freeze
    end

    def gemfile = path("gemfile")
    def next_gemfile = path("next_gemfile")
    def sessions_dir = path("sessions")
    def seeds? = values["seeds"]
    def perform_jobs? = values["perform_jobs"]
    def ignored_columns = values["ignored_columns"]
    def ignored_headers = values["ignored_headers"]
    def boot_timeout = Float(values["boot_timeout"])
    def request_timeout = Float(values["request_timeout"])
    def baseline_path = path("baseline")
    def repro_framework = values["repro_framework"]
    def http_stubs_path = path("http_stubs")
    def ruby = values["ruby"]
    def next_ruby = values["next_ruby"] || values["ruby"]

    # @return [Hash] {"gemfile" => {"path", "version", "source"}, "next_gemfile" => {...}} (ADR 0038)
    def rubies
      require_relative "ruby_locator"
      current = RubyLocator.resolve(ruby, app_root: app_root)
      upcoming = (next_ruby == ruby) ? current : RubyLocator.resolve(next_ruby, app_root: app_root)
      {"gemfile" => current, "next_gemfile" => upcoming}
    end

    # Recorded in run.json.
    def to_options
      {"perform_jobs" => perform_jobs?, "seeds" => seeds?, "ignored_columns" => ignored_columns, "ignored_headers" => ignored_headers}
    end

    private

    def path(key)
      File.expand_path(values[key], app_root)
    end
  end
end
