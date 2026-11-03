# frozen_string_literal: true

# Twin entry point: `ruby lib/doubletrack/twin/main.rb`, spawned by the coordinator with
# cwd = app root, BUNDLE_GEMFILE set, and protocol pipes on DOUBLETRACK_FD_IN/OUT.
#
# Boot order matters (docs/design/protocol.md#environment-hygiene):
#   1. grab protocol fds, 2. redirect stdout/stderr to the log, 3. load the APP's bundle,
#   4. only then require json and our protocol code, 5. boot Rails.
# Nothing here may depend on gems outside the target app's bundle.

started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

protocol_in = IO.for_fd(Integer(ENV.fetch("DOUBLETRACK_FD_IN")), "rb", autoclose: true)
protocol_out = IO.for_fd(Integer(ENV.fetch("DOUBLETRACK_FD_OUT")), "wb", autoclose: true)
protocol_out.sync = true

if (log_path = ENV["DOUBLETRACK_LOG"])
  $stdout.reopen(log_path, "a")
  $stderr.reopen(log_path, "a")
  $stdout.sync = true
  $stderr.sync = true
end

begin
  require "bundler/setup"
  require_relative "../protocol"
  require_relative "worker"
rescue Exception => e # rubocop:disable Lint/RescueException -- report anything, then exit
  # The app bundle could not be set up; json is a default gem so this still works.
  require "json"
  warn "doubletrack twin: bundle setup failed: #{e.class}: #{e.message}"
  protocol_out.write(JSON.generate(
    "schema_version" => 1, "id" => "t-000001", "type" => "error", "reply_to" => nil,
    "payload" => {"code" => "boot_failed", "message" => e.message, "exception_class" => e.class.name,
                  "backtrace" => Array(e.backtrace).first(20)}
  ), "\n")
  exit 1
end

Doubletrack::Twin::Worker.new(input: protocol_in, output: protocol_out, started_at: started_at).run
