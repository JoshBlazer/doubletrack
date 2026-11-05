# frozen_string_literal: true

require "open3"

module Doubletrack
  # Likely causes of each change, found on this machine (ADR 0032,
  # docs/design/changes.md): commits, changelog lines and source files of the
  # dependencies that changed between the two bundles that mention the change's text.
  module Attribution
    MAX_CAUSES = 3
    MAX_FILE_BYTES = 1_000_000
    SOURCE_DIRS = %w[lib ext].freeze

    # The words worth searching for in a change's delta.
    module Needles
      MAX = 3
      MIN_LENGTH = 4
      STOP_WORDS = %w[
        about after also been before being both each from have into just like more most none only other over some such than that
        their them then there these they this those true false null nil when where which while will with would your text html
        json body data true value values
      ].to_set.freeze

      module_function

      # @param change [Hash] with "delta" and "added_runs"
      # @return [Array<String>] at most {MAX}
      def call(change)
        deltas = Array(change["delta"]).select { |d| d.key?("added") }
        return [] if deltas.empty?

        added = deltas.flat_map { |d| d["added"] }
        removed = deltas.flat_map { |d| d["removed"] }
        candidates = Array(change["added_runs"]) + distinctive(added) + distinctive(removed)
        candidates.uniq.first(MAX)
      end

      def distinctive(tokens)
        tokens.select do |t|
          t.length >= MIN_LENGTH && t.match?(/\p{L}/) && !STOP_WORDS.include?(t.downcase)
        end
      end
    end

    # Gems whose version or revision differs between control A and candidate B.
    module DependencyChanges
      SHORT = 10

      module_function

      # @param a [Array<Hash>] hello "gems" of control A
      # @param b [Array<Hash>] hello "gems" of candidate B
      # @return [Array<Hash>] sorted by name
      def call(a, b)
        a_by = Array(a).to_h { |g| [g["name"], g] }
        b_by = Array(b).to_h { |g| [g["name"], g] }
        entries = {}
        (a_by.keys | b_by.keys).sort.each do |name|
          old = a_by[name]
          new = b_by[name]
          next if old && new && old["version"] == new["version"] && old["revision"] == new["revision"]

          if git_pair?(old, new)
            repo = repository_name(new)
            entries[repo] ||= {
              "name" => repo, "from" => label(old), "to" => label(new),
              "from_path" => File.dirname(old["path"].to_s), "to_path" => File.dirname(new["path"].to_s),
              "git" => {"cache" => new["git_cache"], "from" => old["revision"], "to" => new["revision"], "remote" => new["remote"]}
            }
          else
            entries[name] = {"name" => name, "from" => old && label(old), "to" => new && label(new),
                             "from_path" => old && old["path"], "to_path" => new && new["path"], "git" => nil}
          end
        end
        entries.values.sort_by { |e| e["name"] }
      end

      def git_pair?(old, new)
        old && new && old["revision"] && new["revision"] && old["git_cache"] && old["git_cache"] == new["git_cache"]
      end

      # "https://github.com/rails/rails.git" → "rails"
      def repository_name(gem)
        File.basename(gem["remote"].to_s.sub(%r{/+\z}, ""), ".git").then { |n| n.empty? ? gem["name"] : n }
      end

      def label(gem)
        gem["revision"] ? "#{gem["version"]} (#{gem["revision"][0, SHORT]})" : gem["version"]
      end
    end

    module_function

    # @param changes [Array<Hash>] modified in place: "causes", "causes_searched"
    # @param dependency_changes [Array<Hash>]
    # @param budget_s [Numeric] total search time
    # @param git [String] git executable
    # @return [Array<Hash>] changes
    def call(changes, dependency_changes:, budget_s: 60, git: "git")
      deadline = monotonic + budget_s
      deps = Array(dependency_changes)
      files = {}
      changes.each do |change|
        change["causes"] = []
        needles = Needles.call(change)
        next if needles.empty? || deps.empty?

        if monotonic >= deadline
          change["causes_searched"] = false
          next
        end
        causes = []
        needles.each do |needle|
          deps.each do |dep|
            break if causes.size >= MAX_CAUSES || monotonic >= deadline

            commits = commits(dep, needle, git)
            if commits.any?
              causes.concat(commits)
              next
            end
            causes.concat(changelog(dep, needle, files))
            causes.concat(source(dep, needle, files))
          end
        end
        change["causes"] = causes.uniq { |c| [c["dependency"], c["evidence"], c["ref"]] }.first(MAX_CAUSES)
        change["causes_searched"] = false if monotonic >= deadline && causes.size < MAX_CAUSES
      end
      changes
    end

    def commits(dep, needle, git)
      info = dep["git"]
      return [] unless info && info["cache"] && Dir.exist?(info["cache"].to_s) && info["from"] && info["to"]

      out, status = Open3.capture2e(git, "-C", info["cache"], "log", "--format=%H%x1f%s", "-i",
        "-G#{Regexp.escape(needle)}", "--max-count=#{MAX_CAUSES}", "#{info["from"]}..#{info["to"]}")
      return [] unless status.success?

      out.lines.filter_map do |line|
        sha, subject = line.chomp.split("\x1f", 2)
        next unless sha&.match?(/\A\h{40}\z/)

        cause = {"dependency" => dep["name"], "evidence" => "commit", "ref" => sha[0, 10], "text" => subject.to_s, "needle" => needle}
        url = github_url(info["remote"])
        cause["url"] = "#{url}/commit/#{sha}" if url
        cause
      end
    rescue SystemCallError
      []
    end

    # New CHANGELOG.md lines in to_path that mention the needle.
    def changelog(dep, needle, files)
      return [] unless dep["to_path"] && Dir.exist?(dep["to_path"])

      pattern = /#{Regexp.escape(needle)}/i
      changelogs(dep["to_path"], files).filter_map do |relative|
        new_lines = File.readlines(File.join(dep["to_path"], relative), chomp: true)
        old_path = dep["from_path"] && File.join(dep["from_path"], relative)
        old_lines = (old_path && File.exist?(old_path)) ? File.readlines(old_path, chomp: true).to_set : Set.new
        line = new_lines.find { |l| !old_lines.include?(l) && l.match?(pattern) }
        line && {"dependency" => dep["name"], "evidence" => "changelog", "ref" => relative, "text" => line.strip, "needle" => needle}
      end.first(1)
    rescue SystemCallError, ArgumentError
      []
    end

    # A source file that mentions the needle on one side of the upgrade only.
    def source(dep, needle, files)
      return [] unless dep["to_path"] && Dir.exist?(dep["to_path"])

      new_hits = mentions(dep["to_path"], needle, files)
      old_hits = (dep["from_path"] && Dir.exist?(dep["from_path"])) ? mentions(dep["from_path"], needle, files) : []
      if new_hits.any? && old_hits.empty?
        [{"dependency" => dep["name"], "evidence" => "source", "ref" => new_hits.first,
          "text" => dep["from"] ? "appears in #{dep["to"]}, not in #{dep["from"]}" : "appears in #{dep["to"]} (the current bundle hadn't loaded it at boot)", "needle" => needle}]
      elsif old_hits.any? && new_hits.empty?
        [{"dependency" => dep["name"], "evidence" => "source", "ref" => old_hits.first,
          "text" => "appears in #{dep["from"]}, not in #{dep["to"]}", "needle" => needle}]
      else
        []
      end
    end

    def changelogs(root, files)
      (files[[:changelogs, root]] ||= Dir.glob("**/CHANGELOG.md", base: root).sort)
    end

    # @return [Array<String>] relative paths of source files containing the needle
    def mentions(root, needle, files)
      sources = (files[[:sources, root]] ||= SOURCE_DIRS.flat_map { |d| Dir.glob("#{d}/**/*", base: root) }
        .select { |f| File.file?(File.join(root, f)) && File.size(File.join(root, f)) <= MAX_FILE_BYTES }.sort)
      sources.select do |relative|
        text = (files[[:text, root, relative]] ||= File.binread(File.join(root, relative)))
        text.include?(needle.b)
      end
    end

    def github_url(remote)
      m = remote.to_s.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?\z})
      m && "https://github.com/#{m[1]}/#{m[2]}"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
