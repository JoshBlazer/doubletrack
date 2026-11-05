# frozen_string_literal: true

module Doubletrack
  module Twin
    # Copies a snapshot template into a twin's working database through SQLite's online
    # backup API (ADR 0029). Unlike deleting and copying the file, this is safe while other
    # connections are open on it: the app may hold its own (once-campfire's WAL-checkpoint
    # thread opens the file every 250 ms), and SQLite's locks keep each of them consistent.
    # Runs inside a twin, after the app's bundle is loaded (it uses the app's sqlite3 gem).
    module SqliteRestore
      BUSY_TIMEOUT_MS = 5_000
      RETRY_SLEEP = 0.005
      DEADLINE = 30.0

      module_function

      # @param template_path [String]
      # @param database_path [String]
      def call(template_path, database_path)
        raise ArgumentError, "snapshot template not found: #{template_path}" unless File.exist?(template_path)

        require "sqlite3"
        source = SQLite3::Database.new(template_path, readonly: true)
        destination = SQLite3::Database.new(database_path)
        destination.busy_timeout = BUSY_TIMEOUT_MS
        copy(source, destination)
      ensure
        destination&.close
        source&.close
      end

      def copy(source, destination)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
        backup = SQLite3::Backup.new(destination, "main", source, "main")
        loop do
          case backup.step(-1)
          when SQLite3::Constants::ErrorCode::DONE then break
          when SQLite3::Constants::ErrorCode::BUSY, SQLite3::Constants::ErrorCode::LOCKED
            raise Error, "snapshot restore: database stayed locked for #{DEADLINE}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep RETRY_SLEEP
          when SQLite3::Constants::ErrorCode::OK then next
          else raise Error, "snapshot restore failed (SQLite result #{backup.step(0)})"
          end
        end
      ensure
        backup&.finish
      end
    end
  end
end
