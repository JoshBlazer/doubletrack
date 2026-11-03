# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"
require_relative "twin_process"
require_relative "../config"
require_relative "../session"
require_relative "../results"
require_relative "../version"

module Doubletrack
  module Coordinator
    # `doubletrack run`: boot A, A′ and B, build one snapshot, replay every session on all
    # three, store raw traces, then analyze and report (docs/design/diff.md#pipeline).
    class Run
      RUN_VERSION = 1
      ROLES = [["control_a", :gemfile], ["control_a_prime", :gemfile], ["candidate_b", :next_gemfile]].freeze

      Result = Data.define(:dir, :run, :findings)

      # @param config [Config]
      # @param out_dir [String] parent of results/<run_id>
      # @param seed [Integer, nil] run seed; random if nil (always recorded)
      # @param progress [IO]
      def initialize(config:, out_dir: nil, seed: nil, progress: $stderr)
        @config = config
        @out_dir = File.expand_path(out_dir || File.join(config.app_root, "tmp", "doubletrack"))
        @seed = seed || SecureRandom.random_number(1_000_000)
        @progress = progress
      end

      # @return [Result]
      # @raise [Doubletrack::Error]
      def call
        started_at = Time.now.utc
        check_dual_boot!
        sessions = Session.load_dir(@config.sessions_dir)
        run_id = "#{started_at.strftime("%Y%m%dT%H%M%SZ")}-#{@seed}"
        dir = File.join(@out_dir, run_id)
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        timings = {}

        twins = ROLES.map do |role, gemfile|
          TwinProcess.new(role: role, app_root: @config.app_root, gemfile: @config.public_send(gemfile), work_dir: work,
            boot_timeout: @config.boot_timeout, request_timeout: @config.request_timeout)
        end
        begin
          timings["boot_s"] = timed do
            say "Booting control A, control A′ (#{File.basename(@config.gemfile)}) and candidate B (#{File.basename(@config.next_gemfile)})..."
            twins.each(&:spawn_process)
            twins.each(&:await_hello)
          end
          check_versions!(twins)

          snapshot = nil
          timings["snapshot_s"] = timed do
            snapshot = twins.first.prepare_snapshot(template_path: File.join(work, "template.sqlite3"), seed: @seed,
              seeds: @config.seeds?)
          end

          timings["replay_s"] = timed do
            sessions.each_with_index do |session, i|
              progress(i, sessions.size, session.id)
              payload = session.to_payload(run_seed: @seed, snapshot: snapshot["template_path"])
              options = {"perform_jobs" => @config.perform_jobs?}
              results = twins.map { |t| Thread.new { t.run_session(payload, options) } }.map(&:value)
              twins.zip(results).each { |t, r| Results.write_traces(dir, session.id, t.role, r.fetch("traces")) }
            end
            progress(sessions.size, sessions.size, "done")
          end
        ensure
          twins.each(&:stop)
          Dir.glob(File.join(work, "*.sqlite3*")).each { |f| FileUtils.rm_f(f) } # keep twin logs only
        end

        run = {
          "run_version" => RUN_VERSION,
          "run_id" => run_id,
          "seed" => @seed,
          "doubletrack_version" => VERSION,
          "app" => {"name" => twins.first.hello.dig("app", "name"), "root" => @config.app_root},
          "started_at" => started_at.iso8601,
          "finished_at" => Time.now.utc.iso8601,
          "options" => @config.to_options,
          "twins" => twins.to_h { |t| [t.role, t.hello.slice("rails_version", "ruby_version", "bundle_gemfile", "boot_ms", "session_cookie")] },
          "routes" => twins.last.hello["routes"] || twins.first.hello["routes"] || [],
          "snapshot" => snapshot.slice("bytes", "sha256", "tables"),
          "sessions" => sessions.map { |s| {"id" => s.id, "requests" => s.requests.size} },
          "timings" => timings
        }
        run, findings = Results.analyze(dir, run)
        Result.new(dir: dir, run: run, findings: findings)
      end

      private

      def check_dual_boot!
        [@config.gemfile, @config.next_gemfile].each do |path|
          next if File.exist?(path)

          raise ConfigError, "#{path} not found: Doubletrack needs a dual-booted app (next_rails convention, ADR 0001)"
        end
      end

      def check_versions!(twins)
        a, a_prime, b = twins.map { |t| t.hello["rails_version"] }
        raise Error, "control A (#{a}) and control A′ (#{a_prime}) must run the same Rails version" unless a == a_prime
        raise Error, "dual boot not effective: candidate B also loaded Rails #{b} (RISKS R1)" if a == b
      end

      def timed
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      end

      def say(message)
        @progress.puts(message)
      end

      def progress(done, total, label)
        width = 24
        filled = total.zero? ? width : (width * done / total)
        line = format("  [%-#{width}s] %d/%d sessions  %s", "#" * filled, done, total, label)
        if @progress.respond_to?(:tty?) && @progress.tty?
          @progress.print("\r#{line.ljust(70)}")
          @progress.puts if done == total
        else
          @progress.puts(line)
        end
      end
    end
  end
end
