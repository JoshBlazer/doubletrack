# frozen_string_literal: true

require "fileutils"
require "json"

# Builds a results/<run_id> directory with raw traces, as `doubletrack run` leaves it
# before analysis, so analysis, baseline and CLI specs need no twins.
module ResultsFixture
  module_function

  def trace(total, path: "/orders")
    {"trace_version" => 2, "request" => {"index" => 0, "method" => "POST", "path" => path, "params" => {}, "headers" => {}},
     "route" => {"verb" => "POST", "path" => "#{path}(.:format)"}, "time" => "2026-01-01T00:00:00.000000Z",
     "response" => {"status" => 201, "headers" => {"content-type" => "application/json"},
                    "body" => {"encoding" => "utf-8", "data" => JSON.generate("total" => total)}},
     "exception" => nil, "session" => {}, "sql_writes" => [], "jobs" => [], "mail" => [], "cache" => [], "http" => [],
     "deprecations" => [], "performed_jobs" => [], "duration_ms" => 1}
  end

  # @param dir [String] results directory to create
  # @param app_root [String]
  # @param baseline_path [String, nil]
  # @return [Hash] run.json content (pre-analysis)
  def build(dir, app_root:, baseline_path: nil)
    FileUtils.mkdir_p(dir)
    {"control_a" => 1, "control_a_prime" => 1, "candidate_b" => 2}.each do |role, total|
      path = File.join(dir, "traces", "s1", "#{role}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate([trace(total)]))
    end
    run = {
      "run_version" => 1, "run_id" => File.basename(dir), "seed" => 1, "doubletrack_version" => "0.0.1",
      "app" => {"name" => "Shop", "root" => app_root}, "started_at" => "2026-11-03T00:00:00Z", "finished_at" => "2026-11-03T00:00:09Z",
      "options" => {"perform_jobs" => true, "seeds" => false, "ignored_columns" => [], "ignored_headers" => []},
      "twins" => %w[control_a control_a_prime candidate_b].to_h do |r|
        [r, {"rails_version" => (r == "candidate_b") ? "8.1.4" : "8.0.5.1", "ruby_version" => "3.4.12",
             "bundle_gemfile" => "/app/Gemfile", "session_cookie" => "_shop_session"}]
      end,
      "routes" => [{"verb" => "POST", "path" => "/orders(.:format)", "controller" => "orders", "action" => "create"}],
      "sessions" => [{"id" => "s1", "requests" => 1}],
      "timings" => {}
    }
    run["baseline"] = {"path" => baseline_path} if baseline_path
    File.write(File.join(dir, "run.json"), JSON.pretty_generate(run))
    run
  end
end
