# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"
require_relative "twin_process"
require_relative "parallel"
require_relative "../config"
require_relative "../session"
require_relative "../results"
require_relative "../specgen"
require_relative "../version"
require_relative "../rails_label"

module Doubletrack
  module Coordinator
    # `doubletrack run`: boot A, A′ and B, build one snapshot per kind in use, replay every session on all
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
        dir = self.class.claim_dir(@out_dir, "#{started_at.strftime("%Y%m%dT%H%M%SZ")}-#{@seed}")
        run_id = File.basename(dir)
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        timings = {}
        repros = nil

        rubies = @config.rubies
        twins = ROLES.map do |role, gemfile|
          TwinProcess.new(role: role, app_root: @config.app_root, gemfile: @config.public_send(gemfile), work_dir: work,
            boot_timeout: @config.boot_timeout, request_timeout: @config.request_timeout, ruby: rubies.fetch(gemfile.to_s)["path"])
        end
        begin
          timings["boot_s"] = timed do
            a_ruby, b_ruby = rubies.values_at("gemfile", "next_gemfile").map { |r| r["version"] }
            on_rubies = (a_ruby == b_ruby) ? " on Ruby #{a_ruby}" : ""
            say "Booting control A, control A′ (#{File.basename(@config.gemfile)}#{" on Ruby #{a_ruby}" if on_rubies.empty?}) and " \
              "candidate B (#{File.basename(@config.next_gemfile)}#{" on Ruby #{b_ruby}" if on_rubies.empty?})#{on_rubies}..."
            rubies.each_value { |r| say "  .ruby-version asks for Ruby #{r["wanted"]}, which isn't installed; using #{r["version"]}" if r["wanted"] }
            twins.each(&:spawn_process)
            twins.each(&:await_hello)
          end
          check_versions!(twins)

          snapshots = {}
          timings["snapshot_s"] = timed do
            sessions.map(&:snapshot).uniq.sort.each do |kind|
              snapshots[kind] = twins.first.prepare_snapshot(template_path: File.join(work, "template-#{kind}.sqlite3"),
                seed: @seed, seeds: kind == "default" && @config.seeds?, fixtures: kind == "fixtures")
            end
          end
          fidelity = Fidelity.new

          timings["replay_s"] = timed do
            sessions.each_with_index do |session, i|
              progress(i, sessions.size, session.id)
              payload = session.to_payload(run_seed: @seed, snapshot: snapshots.fetch(session.snapshot)["template_path"])
              options = {"perform_jobs" => @config.perform_jobs?}
              results = Coordinator.parallel_map(twins) { |t| t.run_session(payload, options) }
              fidelity.add(session, results.first.fetch("traces"))
              twins.zip(results).each { |t, r| Results.write_traces(dir, session.id, t.role, r.fetch("traces")) }
            end
            progress(sessions.size, sessions.size, "done")
          end

          run = {
            "run_version" => RUN_VERSION,
            "run_id" => run_id,
            "seed" => @seed,
            "doubletrack_version" => VERSION,
            "app" => {"name" => twins.first.hello.dig("app", "name"), "root" => @config.app_root},
            "started_at" => started_at.iso8601,
            "options" => @config.to_options,
            "twins" => twins.to_h { |t| [t.role, t.hello.slice("rails_version", "rails_revision", "ruby_version", "bundle_gemfile", "boot_ms", "session_cookie", "database")] },
            "routes" => twins.last.hello["routes"] || twins.first.hello["routes"] || [],
            "dependency_changes" => Attribution::DependencyChanges.call(twins.first.hello["gems"], twins.last.hello["gems"]),
            "snapshots" => snapshots.transform_values { |s| s.slice("bytes", "sha256", "tables") },
            "sessions" => sessions.map { |s| {"id" => s.id, "requests" => s.requests.size} },
            "baseline" => {"path" => @config.baseline_path},
            "timings" => timings
          }
          run["capture_fidelity"] = fidelity.to_h if fidelity.any?
          run, findings, changes = Results.compute(dir, run)

          repro_s = timed do
            fresh = findings.count { |f| !f["accepted"] }
            say "Verifying reproductions for #{fresh} new finding#{"s" unless fresh == 1}..." if fresh.positive?
            repros = Specgen::Generator.new(
              twins: twins.to_h { |t| [t.role, t] }, sessions: sessions, run_seed: @seed,
              snapshot_paths: snapshots.transform_values { |s| s["template_path"] },
              normalize: {session_cookie: twins.first.hello["session_cookie"], ignored_headers: @config.ignored_headers,
                          ignored_columns: @config.ignored_columns},
              perform_jobs: @config.perform_jobs?, framework: Specgen.framework(@config.app_root, @config.repro_framework),
              dir: dir, progress: @progress
            ).call(findings, run_id: run_id)
          end
          run["timings"]["repro_s"] = repro_s
        ensure
          twins.each(&:stop)
          Dir.glob(File.join(work, "*.sqlite3*")).each { |f| FileUtils.rm_f(f) } # keep twin logs only
        end

        run["finished_at"] = Time.now.utc.iso8601
        Results.write(dir, run, findings, repros, changes)
        Result.new(dir: dir, run: run, findings: findings)
      end

      # Creates and returns <out>/<run_id>, adding -2, -3... if that directory exists (two
      # runs with the same --seed started in the same second).
      def self.claim_dir(out_dir, run_id)
        FileUtils.mkdir_p(out_dir)
        (1..).each do |n|
          dir = File.join(out_dir, (n == 1) ? run_id : "#{run_id}-#{n}")
          Dir.mkdir(dir)
          return dir
        rescue Errno::EEXIST
          next
        end
      end

      # Capture fidelity (ADR 0027): did control A's replay of each captured request get the
      # status its test saw?
      class Fidelity
        MAX_MISMATCHES = 50

        def initialize
          @requests = 0
          @matched = 0
          @mismatches = []
        end

        def add(session, traces)
          session.test_statuses.each_with_index do |expected, i|
            next if expected.nil?

            trace = traces[i] || {}
            replayed = trace["response"] ? trace.dig("response", "status") : "raised"
            @requests += 1
            if replayed == expected
              @matched += 1
            elsif @mismatches.size < MAX_MISMATCHES
              @mismatches << {"session_id" => session.id, "request_index" => i,
                              "request" => "#{session.requests[i]["method"]} #{session.requests[i]["path"]}",
                              "test_status" => expected, "replay_status" => replayed}
            end
          end
        end

        def any? = @requests.positive?

        def to_h = {"requests" => @requests, "matched" => @matched, "mismatches" => @mismatches}
      end

      private

      def check_dual_boot!
        [@config.gemfile, @config.next_gemfile].each do |path|
          next if File.exist?(path)

          raise ConfigError, "#{path} not found: Doubletrack needs a dual-booted app (next_rails convention, ADR 0001)"
        end
      end

      def check_versions!(twins)
        RailsLabel.check!(*twins.map(&:hello))
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
