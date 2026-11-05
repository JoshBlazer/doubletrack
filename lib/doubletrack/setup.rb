# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "errors"

module Doubletrack
  # `doubletrack init` (ADR 0033, docs/design/setup.md): dual boot in one command, writing
  # new files only. The app's Gemfile, lockfile and code are never edited.
  module Setup
    RAILS_STATEMENT = /\A(\s*)gem\s*\(?\s*["']rails["']/
    NEXT_HELPER = /^\s*def\s+next\?/
    SESSIONS_README = <<~TEXT
      # Doubletrack sessions

      Replay sessions for `doubletrack run`, one JSON object per line
      (https://github.com/JoshBlazer/doubletrack/blob/main/docs/formats/session.md).

      Derive them from your integration tests and request specs:

          doubletrack capture

      which writes `captured.jsonl` here. Hand-written `*.jsonl` files sit next to it.
    TEXT

    module_function

    # @param app_root [String]
    # @param to [String, nil] "8.1", "8.1.2" or "main"; default: the next minor version
    # @param force [Boolean] replace an existing Gemfile.next / Gemfile.next.lock
    # @param install [Boolean] run `bundle install` for Gemfile.next
    # @return [Hash] {"from", "requirement", "mode", "written"}
    def init(app_root, to: nil, force: false, install: false, out: $stdout)
      app_root = File.expand_path(app_root)
      gemfile = File.join(app_root, "Gemfile")
      lockfile = File.join(app_root, "Gemfile.lock")
      next_gemfile = File.join(app_root, "Gemfile.next")
      next_lockfile = File.join(app_root, "Gemfile.next.lock")
      raise ConfigError, "#{gemfile} not found: run init in a Rails app's root" unless File.exist?(gemfile)
      raise ConfigError, "#{lockfile} not found: run `bundle install` first, so init knows the current Rails" unless File.exist?(lockfile)

      version, revision = locked_rails(File.read(lockfile))
      raise ConfigError, "#{lockfile} has no rails gem: Doubletrack upgrades Rails apps" unless version

      [next_gemfile, next_lockfile].each do |path|
        next unless File.exist?(path) || File.symlink?(path)
        raise ConfigError, "#{File.basename(path)} already exists: init never overwrites it (pass --force to replace it)" unless force

        FileUtils.rm_f(path)
      end

      text = File.read(gemfile)
      written = []
      if text.match?(NEXT_HELPER)
        mode = "symlink"
        requirement = nil
        File.symlink("Gemfile", next_gemfile)
      else
        mode = "copy"
        requirement = next_requirement(version, to)
        header = "# Written by `doubletrack init` from Gemfile: the same gems, with the next Rails.\n" \
                 "# Keep it in step with Gemfile while you upgrade (`doubletrack doctor` checks both bundles).\n\n"
        File.write(next_gemfile, header + rewrite_rails(text, requirement))
      end
      written << next_gemfile
      FileUtils.cp(lockfile, next_lockfile)
      written << next_lockfile

      sessions = File.join(app_root, "doubletrack", "sessions")
      readme = File.join(sessions, "README.md")
      unless File.exist?(readme)
        FileUtils.mkdir_p(sessions)
        File.write(readme, SESSIONS_README)
        written << readme
      end

      current = revision ? "#{version} (#{revision[0, 10]})" : version
      out.puts("Current Rails: #{current} (Gemfile.lock)")
      if mode == "copy"
        out.puts("Wrote Gemfile.next with gem \"rails\", #{requirement}, and Gemfile.next.lock (a copy, so Bundler moves only Rails and what it needs).")
      else
        out.puts("Your Gemfile defines next? (next_rails convention): linked Gemfile.next to it and copied Gemfile.lock.")
        out.puts("  Set the next Rails in the `if next?` branch of your Gemfile.")
      end
      out.puts("Gemfile, Gemfile.lock and your code are unchanged.")

      installed = install && bundle_install(app_root, out)
      out.puts
      out.puts("Next:")
      out.puts("  BUNDLE_GEMFILE=Gemfile.next bundle install   # resolve and install the next Rails") unless installed
      out.puts("  doubletrack doctor                           # check the setup; boots both versions")
      out.puts("  doubletrack capture                          # sessions from your integration tests")
      out.puts("  doubletrack run                              # replay, compare, report")
      {"from" => current, "requirement" => requirement, "mode" => mode, "written" => written}
    end

    # @return [Array(String, String)] [version, git revision or nil], or [nil, nil]
    def locked_rails(lockfile_text)
      require "bundler"
      spec = Bundler::LockfileParser.new(lockfile_text).specs.find { |s| s.name == "rails" }
      return [nil, nil] unless spec

      source = spec.source
      revision = source.respond_to?(:options) ? source.options["revision"] : nil
      [spec.version.to_s, revision]
    end

    # @param version [String] the current Rails version
    # @param to [String, nil]
    # @return [String] the arguments after `gem "rails", `
    def next_requirement(version, to)
      return 'github: "rails/rails", branch: "main"' if to == "main"

      current = Gem::Version.new(version)
      if to.nil?
        major, minor = current.segments
        target = (minor.to_i >= 2 && major.to_i == 7) ? "#{major + 1}.0.0" : "#{major}.#{minor.to_i + 1}.0"
      else
        raise ConfigError, "--to #{to.inspect}: give a version like 8.1 or 8.1.2, or main" unless to.match?(/\A\d+\.\d+(\.\d+)?\z/)

        target = (to.count(".") == 1) ? "#{to}.0" : to
      end
      if Gem::Version.new(target) <= Gem::Version.new(current.segments.first(3).join("."))
        raise ConfigError, "--to #{to || target}: #{target} is not newer than #{version}"
      end

      %("~> #{target}")
    end

    # Replaces the `gem "rails", ...` statement (continued while lines end in a comma).
    def rewrite_rails(text, requirement)
      lines = text.lines
      start = lines.index { |l| l.match?(RAILS_STATEMENT) }
      raise ConfigError, 'Gemfile has no `gem "rails"` statement to point at the next Rails; add one, or write Gemfile.next yourself' unless start

      finish = start
      finish += 1 while finish < lines.size - 1 && code(lines[finish]).rstrip.end_with?(",")
      indent = lines[start][RAILS_STATEMENT, 1]
      comment = (start == finish) ? lines[start][/\s+#.*$/].to_s.rstrip : ""
      lines[start..finish] = ["#{indent}gem \"rails\", #{requirement}#{comment}\n"]
      lines.join
    end

    # A line without its trailing comment (good enough for Gemfiles: no "#" inside strings
    # on a rails line).
    def code(line)
      line.sub(/\s+#.*$/, "")
    end

    def bundle_install(app_root, out)
      out.puts("Running BUNDLE_GEMFILE=Gemfile.next bundle install...")
      require "bundler"
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e({"BUNDLE_GEMFILE" => File.join(app_root, "Gemfile.next")}, "bundle", "install", chdir: app_root)
      end
      out.puts(output.lines.last(15).join)
      raise ConfigError, "bundle install for Gemfile.next failed (output above)" unless status.success?

      true
    end
  end
end
