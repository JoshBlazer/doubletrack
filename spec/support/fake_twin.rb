# frozen_string_literal: true

# A stand-in twin that speaks the protocol without Rails, for coordinator specs.
# Behavior is selected by FAKE_TWIN_MODE:
#   happy               hello, answers run_session/shutdown
#   noisy               like happy, but spams stdout/stderr first (must not corrupt protocol)
#   crash_before_hello  exits 3 after printing to stderr
#   hang                never sends hello
#   hang_on_request     sends hello, then never answers
#   boot_failed         sends an error/boot_failed instead of hello
#   reject_requests     sends hello, then answers every request with an error that has no
#                       reply_to (what a twin does when it can't read a frame)

require_relative "../../lib/doubletrack/protocol"

mode = ENV.fetch("FAKE_TWIN_MODE", "happy")
input = IO.for_fd(Integer(ENV.fetch("DOUBLETRACK_FD_IN")), "rb")
output = IO.for_fd(Integer(ENV.fetch("DOUBLETRACK_FD_OUT")), "wb")
reader = Doubletrack::Protocol::Reader.new(input)
writer = Doubletrack::Protocol::Writer.new(output)
M = Doubletrack::Protocol::Message

case mode
when "crash_before_hello"
  warn "fake twin: simulated boot crash"
  exit 3
when "hang"
  sleep
when "boot_failed"
  writer.write(M.error(id: "t-000001", code: "boot_failed", message: "simulated boot failure"))
  exit 1
when "noisy"
  1000.times { |i| puts "app noise #{i} {\"schema_version\":1}" }
  warn "stderr noise"
end

writer.write(M.build(id: "t-000001", type: "hello", payload: {
  "role" => ENV["DOUBLETRACK_ROLE"], "pid" => Process.pid, "ruby_version" => RUBY_VERSION,
  "rails_version" => "0.0.fake", "bundle_gemfile" => ENV["BUNDLE_GEMFILE"],
  "rubyopt" => ENV["RUBYOPT"], "gem_home" => ENV["GEM_HOME"], "boot_ms" => 1
}))

sleep if mode == "hang_on_request"

counter = 1
loop do
  request = reader.read
  counter += 1
  id = format("t-%06d", counter)
  if mode == "reject_requests" && request["type"] != "shutdown"
    writer.write(M.error(id: id, code: "bad_message", message: "frame exceeds 67108864 bytes"))
    next
  end
  case request["type"]
  when "run_session"
    traces = request["payload"]["session"]["requests"].each_with_index.map do |r, i|
      {"trace_version" => 1, "request" => {"index" => i, "method" => r["method"], "path" => r["path"]},
       "response" => {"status" => 200, "headers" => {}, "body" => M.encode_body("#{r["method"]} #{r["path"]}")},
       "exception" => nil, "sql_writes" => [], "jobs" => [], "mail" => [], "cache" => [], "http" => []}
    end
    writer.write(M.build(id: id, type: "result", reply_to: request["id"],
      payload: {"session_id" => request["payload"]["session"]["id"], "traces" => traces}))
  when "shutdown"
    writer.write(M.build(id: id, type: "result", reply_to: request["id"], payload: {"ok" => true}))
    exit 0
  else
    writer.write(M.error(id: id, code: "not_implemented", message: request["type"], reply_to: request["id"]))
  end
rescue Doubletrack::Protocol::Closed
  exit 0
end
