# frozen_string_literal: true

require "doubletrack/attribution"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Doubletrack::Attribution do
  def change(summary_delta, runs: [])
    {"id" => "c-1", "delta" => [summary_delta], "added_runs" => runs, "causes" => []}
  end

  describe Doubletrack::Attribution::Needles do
    it "takes distinctive added tokens, then removed ones, and drops short, numeric and common words" do
      c = change({"added" => %w[60 X-Requested-With and max-age], "removed" => %w[Sec-Fetch-Site the]})
      expect(described_class.call(c)).to eq(%w[X-Requested-With max-age Sec-Fetch-Site])
    end

    it "puts runs of added words first and keeps at most three" do
      c = change({"added" => %w[column end input line], "removed" => %w[token]}, runs: ["end of input", "line 1 column 1"])
      expect(described_class.call(c)).to eq(["end of input", "line 1 column 1", "column"])
    end

    it "has nothing to search for an enumerated value change" do
      expect(described_class.call(change({"from" => 200, "to" => 500}))).to eq([])
    end
  end

  describe ".call" do
    around do |example|
      Dir.mktmpdir("dt-attr") do |dir|
        @dir = dir
        example.run
      end
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def git(*args)
      out, status = Open3.capture2e("git", "-C", @repo, *args)
      raise out unless status.success?

      out.strip
    end

    def vary_change
      change({"added" => ["X-Requested-With"], "removed" => []})
    end

    it "names the commit between the two revisions that added the needle, with a GitHub link" do
      @repo = File.join(@dir, "rails.git")
      FileUtils.mkdir_p(@repo)
      git("init", "-q")
      git("config", "user.email", "t@example.com")
      git("config", "user.name", "t")
      write(File.join(@repo, "metal.rb"), "VARY = %w[Accept]\n")
      git("add", "-A")
      git("commit", "-q", "-m", "Initial")
      from = git("rev-parse", "HEAD")
      write(File.join(@repo, "notes.txt"), "unrelated\n")
      git("add", "-A")
      git("commit", "-q", "-m", "Unrelated")
      write(File.join(@repo, "metal.rb"), "VARY = %w[Accept X-Requested-With]\n")
      git("add", "-A")
      git("commit", "-q", "-m", "Vary rendered responses by negotiation headers")
      sha = git("rev-parse", "HEAD")

      deps = [{"name" => "rails", "from" => "8.2.0.alpha (#{from[0, 10]})", "to" => "8.2.0.alpha (#{sha[0, 10]})",
               "from_path" => nil, "to_path" => nil,
               "git" => {"cache" => @repo, "from" => from, "to" => sha, "remote" => "https://github.com/rails/rails.git"}}]
      c = described_class.call([vary_change], dependency_changes: deps).first

      expect(c["causes"]).to eq([{"dependency" => "rails", "evidence" => "commit", "ref" => sha[0, 10],
                                  "text" => "Vary rendered responses by negotiation headers", "needle" => "X-Requested-With",
                                  "url" => "https://github.com/rails/rails/commit/#{sha}"}])
    end

    it "falls back to new changelog lines and to source that mentions the needle on one side only" do
      from_path = File.join(@dir, "rack-3.2.7")
      to_path = File.join(@dir, "rack-3.2.8")
      write(File.join(from_path, "CHANGELOG.md"), "## 3.2.7\n\n- Old entry.\n")
      write(File.join(to_path, "CHANGELOG.md"), "## 3.2.8\n\n- Send X-Requested-With in Vary.\n\n## 3.2.7\n\n- Old entry.\n")
      write(File.join(from_path, "lib/rack/vary.rb"), "VARY = 1\n")
      write(File.join(to_path, "lib/rack/vary.rb"), "VARY = 'X-Requested-With'\n")
      deps = [{"name" => "rack", "from" => "3.2.7", "to" => "3.2.8", "from_path" => from_path, "to_path" => to_path, "git" => nil}]

      c = described_class.call([vary_change], dependency_changes: deps).first

      expect(c["causes"]).to eq([
        {"dependency" => "rack", "evidence" => "changelog", "ref" => "CHANGELOG.md", "text" => "- Send X-Requested-With in Vary.", "needle" => "X-Requested-With"},
        {"dependency" => "rack", "evidence" => "source", "ref" => "lib/rack/vary.rb", "text" => "appears in 3.2.8, not in 3.2.7", "needle" => "X-Requested-With"}
      ])
    end

    it "finds nothing when no dependency mentions the needle, and skips unsearchable changes" do
      to_path = File.join(@dir, "b")
      write(File.join(to_path, "lib/b.rb"), "nothing here\n")
      deps = [{"name" => "b", "from" => "1", "to" => "2", "from_path" => File.join(@dir, "a"), "to_path" => to_path, "git" => nil}]
      changes = described_class.call([vary_change, change({"from" => 200, "to" => 500})], dependency_changes: deps)
      expect(changes.map { |c| c["causes"] }).to eq([[], []])
    end

    it "stops searching when the time budget runs out and says so" do
      deps = [{"name" => "b", "from" => "1", "to" => "2", "from_path" => @dir, "to_path" => @dir, "git" => nil}]
      c = described_class.call([vary_change], dependency_changes: deps, budget_s: 0).first
      expect(c["causes_searched"]).to be(false)
    end
  end

  describe Doubletrack::Attribution::DependencyChanges do
    def gem(name, version, path, revision: nil, cache: nil, remote: nil)
      {"name" => name, "version" => version, "path" => path, "revision" => revision, "git_cache" => cache, "remote" => remote}
    end

    it "keeps gems whose version or revision differs, and folds gems from one git checkout into one entry" do
      a = [gem("rack", "3.2.7", "/g/rack-3.2.7"), gem("json", "2.9.1", "/g/json-2.9.1"),
        gem("actionpack", "8.2.0.alpha", "/g/rails-e3d5/actionpack", revision: "e3d5c569d2aa", cache: "/c/rails", remote: "https://github.com/rails/rails.git"),
        gem("railties", "8.2.0.alpha", "/g/rails-e3d5/railties", revision: "e3d5c569d2aa", cache: "/c/rails", remote: "https://github.com/rails/rails.git")]
      b = [gem("rack", "3.2.8", "/g/rack-3.2.8"), gem("json", "2.9.1", "/g/json-2.9.1"), gem("new_gem", "1.0", "/g/new_gem-1.0"),
        gem("actionpack", "8.2.0.alpha", "/g/rails-8b06/actionpack", revision: "8b06b0eb98bb", cache: "/c/rails", remote: "https://github.com/rails/rails.git"),
        gem("railties", "8.2.0.alpha", "/g/rails-8b06/railties", revision: "8b06b0eb98bb", cache: "/c/rails", remote: "https://github.com/rails/rails.git")]

      expect(described_class.call(a, b)).to eq([
        {"name" => "new_gem", "from" => nil, "to" => "1.0", "from_path" => nil, "to_path" => "/g/new_gem-1.0", "git" => nil},
        {"name" => "rack", "from" => "3.2.7", "to" => "3.2.8", "from_path" => "/g/rack-3.2.7", "to_path" => "/g/rack-3.2.8", "git" => nil},
        {"name" => "rails", "from" => "8.2.0.alpha (e3d5c569d2)", "to" => "8.2.0.alpha (8b06b0eb98)", "from_path" => "/g/rails-e3d5", "to_path" => "/g/rails-8b06",
         "git" => {"cache" => "/c/rails", "from" => "e3d5c569d2aa", "to" => "8b06b0eb98bb", "remote" => "https://github.com/rails/rails.git"}}
      ])
    end

    it "keeps released gems as separate entries, each with its own changelog" do
      a = %w[actionpack activerecord railties].map { |n| gem(n, "8.0.5.1", "/g/#{n}-8.0.5.1") }
      b = %w[actionpack activerecord railties].map { |n| gem(n, "8.1.4", "/g/#{n}-8.1.4") }
      names = described_class.call(a, b).map { |d| d["name"] }
      expect(names).to eq(%w[actionpack activerecord railties])
    end
  end
end
