# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "errors"
require_relative "setup"
require_relative "config"

module Doubletrack
  # `doubletrack doctor` (ADR 0034, docs/design/setup.md): checks an app's setup and says
  # how to fix each problem, before a long run fails.
  class Doctor
    UNINTERCEPTED_HTTP = %w[httpx typhoeus curb excon patron http].freeze
    STATUS_MARKS = {"ok" => "ok  ", "warn" => "warn", "fail" => "FAIL"}.freeze

    # @param checks [Array<Hash>]
    # @return [Integer] 0 when nothing failed, 1 otherwise
    def self.exit_code(checks) = (checks.any? { |c| c["status"] == "fail" }) ? 1 : 0

    # @param app_root [String]
    # @param boot [Boolean] boot control A and candidate B
    # @param bundle_check [#call, nil] (gemfile path) -> [ok, output]; `bundle check` by default
    def initialize(app_root, boot: true, bundle_check: nil, config: nil)
      @app_root = File.expand_path(app_root)
      @boot = boot
      @bundle_check = bundle_check || method(:bundle_check)
      @config = config
    end

    # @return [Array<Hash>] {"name", "status", "detail", "fix"}
    def checks
      list = [platform, ruby, dual_boot]
      list << rails_versions if dual_boot_files?
      list << bundles if dual_boot_files?
      list.push(database, http_clients, sessions, git)
      list << boot_check if @boot && list.none? { |c| c["status"] == "fail" }
      list
    end

    # Prints one line per check, then a summary.
    # @return [Integer] exit code
    def report(out)
      results = checks
      out.puts("Doubletrack doctor: #{@app_root}")
      results.each do |c|
        out.puts("  #{STATUS_MARKS.fetch(c["status"])}  #{c["name"]}: #{c["detail"]}")
        out.puts("        fix: #{c["fix"]}") if c["fix"] && c["status"] != "ok"
      end
      failed = results.count { |c| c["status"] == "fail" }
      warned = results.count { |c| c["status"] == "warn" }
      out.puts(failed.zero? ? "Ready#{" (#{warned} warning#{"s" unless warned == 1})" if warned.positive?}: run `doubletrack capture`, then `doubletrack run`." : "#{failed} problem#{"s" unless failed == 1} to fix before `doubletrack run`.")
      self.class.exit_code(results)
    end

    private

    def check(name, status, detail, fix = nil) = {"name" => name, "status" => status, "detail" => detail, "fix" => fix}

    def path(*parts) = File.join(@app_root, *parts)

    def gemfile = @config ? @config.gemfile : path("Gemfile")

    def next_gemfile = @config ? @config.next_gemfile : path("Gemfile.next")

    def lock_for(gemfile) = "#{gemfile}.lock".sub(/Gemfile\.lock\z/, "Gemfile.lock")

    def platform
      if Gem.win_platform?
        check("platform", "fail", "native Windows (#{RUBY_PLATFORM})", "run Doubletrack in WSL (ADR 0003)")
      else
        check("platform", "ok", RUBY_PLATFORM)
      end
    end

    def ruby
      if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")
        return check("ruby", "fail", "Ruby #{RUBY_VERSION}", "use Ruby 3.2 or newer")
      end

      rubies = begin
        (@config || Config.load(@app_root)).rubies
      rescue ConfigError => e
        return check("ruby", "fail", e.message, "install that Ruby, or change ruby/next_ruby in doubletrack.yml")
      end
      a, b = rubies.values_at("gemfile", "next_gemfile")
      sides = (a["path"] == b["path"]) ? "both sides on Ruby #{a["version"]}" : "control A on Ruby #{a["version"]}, candidate B on Ruby #{b["version"]}"
      wanted = [a, b].filter_map { |r| r["wanted"] }.first
      if wanted
        check("ruby", "warn", "the app's .ruby-version says #{wanted}, which isn't installed: #{sides} (#{RUBY_VERSION} is running Doubletrack)",
          "install Ruby #{wanted} (Doubletrack finds rbenv, asdf, mise, chruby and rvm installs), or set ruby in doubletrack.yml")
      else
        check("ruby", "ok", sides)
      end
    end

    def dual_boot_files
      [gemfile, lock_for(gemfile), next_gemfile, lock_for(next_gemfile)]
    end

    def dual_boot_files? = dual_boot_files.all? { |f| File.exist?(f) }

    def dual_boot
      missing = dual_boot_files.reject { |f| File.exist?(f) }.map { |f| File.basename(f) }
      return check("dual boot", "ok", "Gemfile + Gemfile.lock, Gemfile.next + Gemfile.next.lock") if missing.empty?

      fix = if missing.include?(File.basename(next_gemfile))
        "doubletrack init (writes Gemfile.next for the next Rails)"
      elsif missing.include?(File.basename(lock_for(next_gemfile)))
        "BUNDLE_GEMFILE=Gemfile.next bundle install"
      else
        "bundle install"
      end
      check("dual boot", "fail", "missing #{missing.join(", ")}", fix)
    end

    def rails_versions
      current = Setup.locked_rails(File.read(lock_for(gemfile)))
      upcoming = Setup.locked_rails(File.read(lock_for(next_gemfile)))
      label = ->((v, r)) { r ? "#{v} (#{r[0, 10]})" : v.to_s }
      detail = "#{label.call(current)} → #{label.call(upcoming)}"
      if current.first.nil? || upcoming.first.nil?
        check("rails versions", "fail", "no rails gem in #{current.first ? "Gemfile.next.lock" : "Gemfile.lock"}", "add Rails to both Gemfiles")
      elsif current == upcoming
        check("rails versions", "fail", "both lockfiles have Rails #{label.call(current)}", "point Gemfile.next at the next Rails, then BUNDLE_GEMFILE=Gemfile.next bundle install")
      elsif adjacent?(current.first, upcoming.first)
        check("rails versions", "ok", detail)
      else
        check("rails versions", "warn", "#{detail}: not adjacent minor versions, so many changes land in one report (ADR 0008)",
          "upgrade one minor version at a time")
      end
    end

    def adjacent?(a, b)
      x = Gem::Version.new(a).segments.first(2)
      y = Gem::Version.new(b).segments.first(2)
      return true if x == y # same minor (patch or git revisions)

      (y == [x[0], x[1] + 1]) || (y[1].zero? && y[0] == x[0] + 1)
    end

    def bundles
      failures = [gemfile, next_gemfile].filter_map do |g|
        ok, output = @bundle_check.call(g)
        "#{File.basename(g)}: #{output.lines.reject { |l| l.strip.empty? }.first(2).join(" ").strip}" unless ok
      end
      if failures.empty?
        check("bundles", "ok", "both bundles are installed")
      else
        check("bundles", "fail", failures.join("; "), "bundle install, and BUNDLE_GEMFILE=Gemfile.next bundle install")
      end
    end

    def bundle_check(gemfile)
      require "bundler"
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e({"BUNDLE_GEMFILE" => gemfile}, "bundle", "check", chdir: @app_root)
      end
      [status.success?, output]
    rescue SystemCallError => e
      [false, e.message]
    end

    def database
      config_path = path("config", "database.yml")
      return check("database", "fail", "no config/database.yml", "Doubletrack needs an Active Record app with SQLite") unless File.exist?(config_path)

      adapter = test_adapter(config_path)
      postgres = adapter.to_s.start_with?("postg")
      if adapter && !adapter.include?("sqlite") && !postgres
        return check("database", "fail", "the test database uses #{adapter}; Doubletrack supports SQLite and PostgreSQL",
          "point the test database at SQLite or PostgreSQL")
      end
      if postgres && !gem_in_lockfiles?("pg")
        return check("database", "fail", "the test database uses PostgreSQL but the pg gem isn't in the bundle", "add gem \"pg\" to the Gemfile")
      end
      unless File.exist?(path("db", "schema.rb"))
        fix = File.exist?(path("db", "structure.sql")) ? "set config.active_record.schema_format = :ruby and dump db/schema.rb" : "bin/rails db:schema:dump"
        return check("database", "fail", "no db/schema.rb (snapshots are built from it)", fix)
      end
      label = postgres ? "PostgreSQL (13 or newer; each twin gets its own database, ADR 0037)" : "SQLite (#{adapter || "sqlite3"})"
      check("database", "ok", "#{label}, db/schema.rb")
    end

    def gem_in_lockfiles?(name)
      [gemfile, next_gemfile].any? do |g|
        lock = lock_for(g)
        File.exist?(lock) && File.read(lock).match?(/^ {4}#{Regexp.escape(name)} \(/)
      end
    end

    # The test environment's adapter, reading ERB-free YAML; nil when it can't tell.
    def test_adapter(config_path)
      text = File.read(config_path).gsub(/<%.*?%>/m, "x")
      data = YAML.safe_load(text, aliases: true) || {}
      test = data["test"]
      return nil unless test.is_a?(Hash)

      test = test["primary"] || test.values.find { |v| v.is_a?(Hash) } if test["adapter"].nil?
      test.is_a?(Hash) ? test["adapter"]&.to_s : nil
    rescue Psych::Exception
      nil
    end

    def http_clients
      names = [gemfile, next_gemfile].flat_map do |g|
        lock = lock_for(g)
        File.exist?(lock) ? File.read(lock).scan(/^ {4}([a-z0-9_-]+) \(/).flatten : []
      end
      found = (names & UNINTERCEPTED_HTTP).uniq.sort
      if found.empty?
        check("http clients", "ok", "no HTTP clients that bypass Net::HTTP")
      else
        check("http clients", "warn", "#{found.join(", ")} in the bundle: calls through #{(found.size == 1) ? "it are" : "them are"} not intercepted (only Net::HTTP is)",
          "make sure replayed requests don't call out through #{found.join(" or ")}, or stub at the app level")
      end
    end

    def sessions
      dir = path("doubletrack", "sessions")
      files = Dir.glob(File.join(dir, "*.jsonl"))
      if files.empty?
        check("sessions", "warn", "no doubletrack/sessions/*.jsonl yet", "doubletrack capture (derives sessions from your integration tests)")
      else
        check("sessions", "ok", "#{files.size} session file#{"s" unless files.size == 1}")
      end
    end

    def git
      _, status = Open3.capture2e("git", "--version")
      status.success? ? check("git", "ok", "git available (likely causes can name commits)") : raise(SystemCallError, "git")
    rescue SystemCallError
      check("git", "warn", "no git on the PATH", "install git so likely causes can name the commit (ADR 0032)")
    end

    def boot_check
      require_relative "coordinator/twin_process"
      require_relative "rails_label"
      Dir.mktmpdir("doubletrack-doctor") do |work|
        rubies = (@config || Config.load(@app_root)).rubies
        twins = {"control_a" => [gemfile, "gemfile"], "candidate_b" => [next_gemfile, "next_gemfile"]}.map do |role, (g, side)|
          Coordinator::TwinProcess.new(role: role, app_root: @app_root, gemfile: g, work_dir: work, boot_timeout: 120, request_timeout: 30,
            ruby: rubies.fetch(side)["path"])
        end
        begin
          twins.each(&:spawn_process)
          hellos = twins.map do |t|
            t.await_hello
            t.hello
          rescue Error => e
            return check("boot", "fail", "#{t.role} (#{File.basename(t.gemfile)}) didn't boot: #{e.message.lines.first.to_s.strip}",
              "read its log: #{t.log_tail.to_s.lines.last(5).join.strip}")
          end
          a, b = hellos.map { |h| RailsLabel.label(h) }
          if a == b
            return check("boot", "fail", "both loaded Rails #{a}: dual boot isn't effective (RISKS R1)", "check BUNDLE_GEMFILE handling and Gemfile.next")
          end

          times = hellos.map { |h| "#{(h["boot_ms"].to_f / 1000).round(1)} s" }
          check("boot", "ok", "control A booted Rails #{a} in #{times[0]}, candidate B Rails #{b} in #{times[1]}")
        ensure
          twins.each(&:stop)
        end
      end
    end
  end
end
