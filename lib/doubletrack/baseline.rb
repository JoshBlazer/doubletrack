# frozen_string_literal: true

require "fileutils"
require "time"
require "yaml"
require_relative "errors"

module Doubletrack
  # `doubletrack.baseline.yml`: findings accepted as expected (docs/formats/baseline.md,
  # ADR 0024). Strict on read: a malformed baseline must never silently hide or show
  # findings.
  class Baseline
    FILE = "doubletrack.baseline.yml"
    VERSION = 1
    ID_PATTERN = /\Af-\h{12}\z/
    REQUIRED = %w[id reason author accepted_at].freeze
    OPTIONAL = %w[title severity rails run_id].freeze
    ORDER = %w[id title severity reason author accepted_at rails run_id].freeze
    HEADER = <<~YAML
      # Doubletrack baseline: findings accepted as expected upgrade differences.
      # Written by `doubletrack accept`. Review changes to this file like code.
      # Format: docs/formats/baseline.md in the Doubletrack repository.
    YAML

    attr_reader :path

    # @param path [String]
    # @return [Baseline] empty if the file doesn't exist
    # @raise [ConfigError] malformed file
    def self.load(path)
      return new(path, [], exists: false) unless File.exist?(path)

      data = YAML.safe_load_file(path)
      invalid!(path, "expected a mapping with baseline_version and accepted") unless data.is_a?(Hash)
      extra = data.keys - %w[baseline_version accepted]
      invalid!(path, "unknown key #{extra.first.inspect}") unless extra.empty?
      invalid!(path, "baseline_version must be #{VERSION} (got #{data["baseline_version"].inspect})") unless data["baseline_version"] == VERSION
      entries = data["accepted"] || []
      invalid!(path, "accepted must be a list") unless entries.is_a?(Array)

      seen = {}
      entries.each_with_index do |e, i|
        where = "accepted[#{i}]"
        invalid!(path, "#{where} must be a mapping") unless e.is_a?(Hash)
        unknown = e.keys - REQUIRED - OPTIONAL
        invalid!(path, "#{where}: unknown key #{unknown.first.inspect}") unless unknown.empty?
        REQUIRED.each do |key|
          invalid!(path, "#{where}: #{key} is required and must not be blank") unless e[key].is_a?(String) && !e[key].strip.empty?
        end
        invalid!(path, "#{where}: id #{e["id"].inspect} is not a finding id (f- and 12 hex digits)") unless ID_PATTERN.match?(e["id"])
        invalid!(path, "#{where}: duplicate id #{e["id"]}") if seen[e["id"]]

        seen[e["id"]] = true
      end
      new(path, entries, exists: true)
    rescue Psych::Exception => e
      invalid!(path, e.message)
    end

    def self.invalid!(path, message)
      raise ConfigError, "#{path}: invalid baseline: #{message}"
    end

    def initialize(path, entries, exists:)
      @path = path
      @entries = entries.map(&:dup)
      @exists = exists
    end

    def exist? = @exists

    def entries = @entries.map(&:dup)

    def ids = @entries.map { |e| e["id"] }

    def entry(id) = @entries.find { |e| e["id"] == id }&.dup

    # Adds or replaces the entry for a finding.
    # @param finding [Hash] from findings.json
    # @param reason [String]
    # @param author [String]
    # @param run [Hash] run.json (for context fields)
    # @param now [Time]
    # @return [Symbol] :added or :updated
    def accept(finding, reason:, author:, run:, now: Time.now)
      raise ConfigError, "a reason is required (--reason TEXT): why is this difference expected?" if reason.to_s.strip.empty?
      raise ConfigError, "an author is required (--author TEXT, or set git config user.name)" if author.to_s.strip.empty?

      from = run.dig("twins", "control_a", "rails_version")
      to = run.dig("twins", "candidate_b", "rails_version")
      entry = {
        "id" => finding.fetch("id"),
        "title" => finding["title"],
        "severity" => finding["severity"],
        "reason" => reason.strip,
        "author" => author.strip,
        "accepted_at" => now.utc.iso8601,
        "rails" => (from && to) ? "#{from} → #{to}" : nil,
        "run_id" => run["run_id"]
      }.compact
      existing = @entries.index { |e| e["id"] == entry["id"] }
      if existing
        @entries[existing] = entry
        :updated
      else
        @entries << entry
        :added
      end
    end

    # Writes the file, entries sorted by id.
    def write
      sorted = @entries.sort_by { |e| e["id"] }.map { |e| ORDER.filter_map { |k| [k, e[k]] if e.key?(k) }.to_h }
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, HEADER + YAML.dump({"baseline_version" => VERSION, "accepted" => sorted}).delete_prefix("---\n"))
      @exists = true
      path
    end

    # @param findings [Array<Hash>]
    # @return [Array(Array<Hash>, Array<String>)] findings (accepted ones marked) and stale ids
    def apply(findings)
      by_id = @entries.to_h { |e| [e["id"], e] }
      seen = {}
      marked = findings.map do |f|
        e = by_id[f["id"]]
        next f unless e

        seen[f["id"]] = true
        f.merge("accepted" => e.slice("reason", "author", "accepted_at"))
      end
      [marked, ids.reject { |id| seen[id] }]
    end
  end
end
