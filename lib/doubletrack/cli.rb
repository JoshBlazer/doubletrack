# frozen_string_literal: true

require_relative "../doubletrack"

module Doubletrack
  # Command-line entry point. Only `version` and `help` work in M0; every other command
  # says which milestone delivers it and exits 2, so nothing pretends to work.
  class CLI
    COMMANDS = {
      "init" => ["detect Rails version, set up/verify dual boot, write doubletrack.yml", "M5"],
      "doctor" => ["verify both versions boot and report environment problems", "M5"],
      "capture" => ["derive sessions from the app's request/integration tests", "M5"],
      "run" => ["replay sessions on control A, control A', and candidate B", "M3"],
      "report" => ["(re)generate the static HTML report from stored results", "M3"],
      "accept" => ["mark a finding as expected in doubletrack.baseline.yml", "M4"],
      "bisect" => ["find the Rails version, then commit, that introduced a finding", "L1"],
      "defaults" => ["test each new framework default individually", "L2"]
    }.freeze

    def self.start(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).call(argv)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    # @return [Integer] exit code
    def call(argv)
      command = argv.first
      case command
      when nil, "help", "-h", "--help"
        @out.puts(usage)
        EXIT_OK
      when "version", "-v", "--version"
        @out.puts("doubletrack #{VERSION}")
        EXIT_OK
      when *COMMANDS.keys
        @err.puts("doubletrack #{command}: not implemented yet (planned for #{COMMANDS[command][1]}; see docs/ROADMAP.md)")
        EXIT_ERROR
      else
        @err.puts("doubletrack: unknown command #{command.inspect}\n\n#{usage}")
        EXIT_ERROR
      end
    end

    private

    def usage
      lines = COMMANDS.map { |name, (summary, milestone)| format("  %-9s %s [%s]", name, summary, milestone) }
      <<~USAGE
        Usage: doubletrack COMMAND [options]

        Upgrade Rails with proof, not hope.

        Commands (milestone that delivers each in brackets):
        #{lines.join("\n")}
          version   print the version

        Exit codes: 0 no new differences, 1 new differences found, 2 Doubletrack error.
      USAGE
    end
  end
end
