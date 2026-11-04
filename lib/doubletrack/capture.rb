# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "time"
require "tmpdir"
require_relative "errors"
require_relative "version"
require_relative "config"
require_relative "session"
require_relative "specgen"
require_relative "capture/record"
require_relative "capture/assembler"

module Doubletrack
  # `doubletrack capture`: run the app's tests once on the current Rails with the probe
  # loaded, and turn their integration requests into sessions (docs/design/capture.md).
  module Capture
    BOOT = File.expand_path("capture/boot.rb", __dir__)
    RSPEC = 'load Gem.bin_path("rspec-core", "rspec")'
    OUTPUT_TAIL = 30

    Summary = Data.define(:path, :command, :stats, :tests_passed, :exit_status, :output_tail)

    # The end of the test output, plus the exception message above a Ruby backtrace when
    # the tail would cut it off: a boot error prints its message first, then the trace.
    # @return [String]
    def self.output_excerpt(output, tail: OUTPUT_TAIL)
      lines = output.to_s.lines
      return lines.join if lines.size <= tail

      first_from = lines.index { |l| l.start_with?("	from ") }
      kept = lines.last(tail)
      return kept.join if first_from.nil? || first_from.zero?

      start = lines.size - tail
      message_at = first_from - 1
      return kept.join if message_at >= start

      omitted = start - first_from
      lines[message_at, 1].join + ((omitted > 0) ? "	... #{omitted} lines omitted ...
" : "") + kept.join
    end

    # The default test command (a Ruby script and its arguments) for an app.
    # @return [Array<String>]
    def self.default_command(config)
      (Specgen.framework(config.app_root, config.repro_framework) == "rspec") ? ["-e", RSPEC] : ["bin/rails", "test"]
    end

    # Runs the capture.
    class Runner
      # @param config [Config]
      # @param out [String, nil] sessions file (default doubletrack/sessions/captured.jsonl in the app)
      # @param command [String, nil] Ruby script and arguments, e.g. "bin/rails test test/integration"
      # @param progress [IO]
      def initialize(config:, out: nil, command: nil, progress: $stderr, env: ENV)
        @config = config
        @out = File.expand_path(out || File.join(config.sessions_dir, "captured.jsonl"), config.app_root)
        @command = command ? Shellwords.split(command) : Capture.default_command(config)
        @progress = progress
        @env = env
      end

      # @return [Summary]
      # @raise [Doubletrack::Error]
      def call
        raise ConfigError, "#{@config.gemfile} not found: capture runs the app's tests on its current Gemfile" unless File.exist?(@config.gemfile)
        raise ConfigError, "empty --command" if @command.empty?

        stubs = http_stubs
        Dir.mktmpdir("doubletrack-capture-") do |dir|
          @progress.puts("Running `#{display_command}` on #{File.basename(@config.gemfile)} with the capture probe...")
          output, status = run_tests(dir)
          records = read_records(dir)
          tail = Capture.output_excerpt(output)
          if records.empty?
            raise Error, "no requests were captured by `#{display_command}` (exit #{status&.exitstatus.inspect}). " \
              "Capture needs integration tests or request specs that call get/post/....\n--- last lines of the test output ---\n#{tail}"
          end

          result = Assembler.new(http_stubs: stubs, secrets: Assembler.secrets_from(@env.to_h)).call(records)
          if result.sessions.empty?
            raise Error, "every captured test was skipped: " + result.stats["skipped"].map { |s| "#{s["test"]}: #{s["reason"]}" }.join("; ")
          end

          FileUtils.mkdir_p(File.dirname(@out))
          File.write(@out, Assembler.to_jsonl(result, header: header))
          Summary.new(path: @out, command: display_command, stats: result.stats, tests_passed: status&.success? || false,
            exit_status: status&.exitstatus, output_tail: tail)
        end
      end

      private

      def display_command
        Shellwords.join(@command)
      end

      def run_tests(dir)
        env = {"BUNDLE_GEMFILE" => @config.gemfile, "RAILS_ENV" => "test", "RACK_ENV" => "test",
               "DOUBLETRACK_CAPTURE_DIR" => dir, "RUBYOPT" => nil, "RUBYLIB" => nil}
        Bundler.with_unbundled_env do
          Open3.capture2e(env, RbConfig.ruby, "-r#{BOOT}", *@command, chdir: @config.app_root)
        end
      rescue SystemCallError => e
        raise Error, "could not start `#{display_command}`: #{e.message}"
      end

      def read_records(dir)
        Dir.glob(File.join(dir, "capture-*.jsonl")).sort.flat_map do |file|
          File.foreach(file).filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
      end

      def http_stubs
        path = @config.http_stubs_path
        return [] unless File.exist?(path)

        stubs = JSON.parse(File.read(path))
        raise ConfigError, "#{path}: expected a JSON array of HTTP stubs (docs/formats/session.md)" unless stubs.is_a?(Array)

        # Validate through the session parser so a bad stub fails here, not at replay.
        Session.new({"session_version" => Session::VERSION, "id" => "stubs", "requests" => [{"path" => "/"}],
                     "http_stubs" => stubs}, source: path)
        stubs
      rescue JSON::ParserError => e
        raise ConfigError, "#{path}: invalid JSON: #{e.message.lines.first&.strip}"
      end

      def header
        [
          "Captured by `doubletrack capture` (Doubletrack #{VERSION}) at #{Time.now.utc.iso8601}",
          "from `#{display_command}` on #{File.basename(@config.gemfile)}. Regenerate rather than edit: this file is overwritten.",
          "Format: docs/formats/session.md in the Doubletrack repository; design: docs/design/capture.md."
        ]
      end
    end
  end
end
