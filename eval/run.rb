# frozen_string_literal: true

# `make eval`: precision/recall on the planted fixtures. Writes eval/results/<date>.json
# and exits 1 if recall or precision is below 1.0, the clean app has any finding, or any
# finding lacks a reproduction that passes on the current Rails and fails on the next.
#
#   ruby eval/run.rb [--seed N] [--no-write]

require "optparse"
require "time"
require "tmpdir"
require_relative "harness"

seed = 7
write = true
OptionParser.new do |o|
  o.on("--seed N", Integer) { |v| seed = v }
  o.on("--no-write", "do not write eval/results/") { write = false }
end.parse!

report = Dir.mktmpdir("doubletrack-eval-") do |dir|
  DoubletrackEval::Harness.new(out_dir: dir, seed: seed).call
end
report["date"] = Time.now.utc.iso8601
report["apps"].each_value { |app| app.delete("results_dir") } # pointed into the deleted temp dir

puts
puts "Doubletrack eval (seed #{seed}), Rails #{report.dig("apps", "changes", "rails").join(" → ")}"
report["apps"].each do |name, app|
  printf("  %-8s findings %-3d plants %-2d caught %-2d missed %-2d unexpected %-2d precision %.2f recall %.2f noise filtered %d\n",
    name, app["findings"], app["plants"], app["caught"].size, app["missed"].size, app["unexpected"].size,
    app["precision"], app["recall"], app["noise_suppressed"])
  if (rp = app["repros"]) && rp["generated"].positive?
    printf("  %-8s repros %d: verified in run %d, pass on current %d, fail on next %d, confirmed %d\n",
      "", rp["generated"], rp["verified_in_run"], rp["pass_on_current"], rp["fail_on_next"], rp["confirmed"])
    rp["unconfirmed"].each { |id| puts "    unconfirmed repro: #{id}" }
  end
  app["missed"].each { |id| puts "    missed: #{id}" }
  app["unexpected"].each { |f| puts "    unexpected: [#{f["severity"]}] #{f["route"]} #{f["path"]} #{f["op"]}" }
end
puts "  #{report["pass"] ? "PASS" : "FAIL"}"

if write
  dir = File.join(__dir__, "results")
  FileUtils.mkdir_p(dir)
  path = File.join(dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.json")
  File.write(path, JSON.pretty_generate(report) + "\n")
  puts "  written: #{path.delete_prefix("#{DoubletrackEval::ROOT}/")}"
end
exit(report["pass"] ? 0 : 1)
