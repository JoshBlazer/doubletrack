# frozen_string_literal: true

require "doubletrack/twin/loaded_gems"

RSpec.describe Doubletrack::Twin::LoadedGems do
  it "lists loaded gems with their version and path, sorted by name" do
    gems = described_class.call
    rspec = gems.find { |g| g["name"] == "rspec-core" }
    expect(rspec).to include("version" => RSpec::Core::Version::STRING, "revision" => nil, "git_cache" => nil, "remote" => nil)
    expect(File.directory?(rspec["path"])).to be(true)
    expect(gems.map { |g| g["name"] }).to eq(gems.map { |g| g["name"] }.sort)
  end

  it "reports a git source's revision, clone and remote, without credentials in the remote" do
    source = Class.new do
      def self.name = "Bundler::Source::Git"
      def revision = "e3d5c569d217c56c022b04acb127a8c24dbe9685"
      def cache_path = "/bundle/cache/bundler/git/rails-fcf0"
      def uri = "https://user:s3cret@github.com/rails/rails.git"
    end.new
    spec = Struct.new(:name, :version, :full_gem_path, :source).new("actionpack", Gem::Version.new("8.2.0.alpha"), "/bundle/gems/rails-e3d5/actionpack", source)

    expect(described_class.call([spec])).to eq([{"name" => "actionpack", "version" => "8.2.0.alpha", "path" => "/bundle/gems/rails-e3d5/actionpack",
                                                 "revision" => "e3d5c569d217c56c022b04acb127a8c24dbe9685", "git_cache" => "/bundle/cache/bundler/git/rails-fcf0",
                                                 "remote" => "https://github.com/rails/rails.git"}])
  end
end
