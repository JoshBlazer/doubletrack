# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "../protocol"

module Doubletrack
  module Coordinator
    # One twin: a separate Ruby process that boots the target app on one bundle and
    # answers protocol requests on fds 3/4. See docs/design/protocol.md.
    #
    # @example
    #   twin = TwinProcess.new(role: "control_a", app_root: "app", gemfile: "app/Gemfile", work_dir: "tmp/run")
    #   twin.start                       # => hello payload
    #   twin.run_session(session_hash)   # => result payload
    #   twin.stop
    class TwinProcess
      ROLES = %w[control_a control_a_prime candidate_b repro].freeze
      TWIN_MAIN = File.expand_path("../twin/main.rb", __dir__)
      CHILD_FD_IN = 3
      CHILD_FD_OUT = 4
      LOG_TAIL_LINES = 40
      KILL_GRACE_SECONDS = 5
      # Shared by every twin in a run so session cookies are identical across twins.
      SECRET_KEY_BASE = ("doubletrack" * 12).freeze

      attr_reader :role, :app_root, :gemfile, :work_dir, :log_path, :pid, :hello

      # @param role [String] one of {ROLES}
      # @param app_root [String] target app directory (the twin's cwd)
      # @param gemfile [String] BUNDLE_GEMFILE for this twin
      # @param work_dir [String] private directory for this run (logs, databases)
      # @param command [Array<String>] argv; defaults to the real twin entry point
      # @param env [Hash{String=>String}] extra environment for the twin
      # @param boot_timeout [Numeric] seconds to wait for hello
      # @param request_timeout [Numeric] seconds to wait for each reply
      def initialize(role:, app_root:, gemfile:, work_dir:, command: nil, env: {},
        boot_timeout: 120, request_timeout: 60)
        raise ArgumentError, "unknown role #{role.inspect} (expected one of #{ROLES.join(", ")})" unless ROLES.include?(role)

        @role = role
        @app_root = File.expand_path(app_root)
        @gemfile = File.expand_path(gemfile)
        @work_dir = File.expand_path(work_dir)
        @command = command || [RbConfig.ruby, TWIN_MAIN]
        @extra_env = env
        @boot_timeout = boot_timeout
        @request_timeout = request_timeout
        @log_path = File.join(@work_dir, "twin-#{role}.log")
        @database_path = File.join(@work_dir, "#{role}.sqlite3")
        @next_id = 0
        @status = nil
      end

      # Spawns the twin and waits for hello.
      # @return [Hash] the hello payload
      # @raise [TwinBootFailed, TwinCrashed, TwinTimeout, Protocol::ProtocolError]
      def start
        spawn_process
        await_hello
      end

      # Spawns the process without waiting, so several twins can boot in parallel.
      # Pair with {#await_hello}.
      # @return [Integer] pid
      def spawn_process
        FileUtils.mkdir_p(@work_dir)
        to_child_r, to_child_w = IO.pipe
        from_child_r, from_child_w = IO.pipe

        @pid = with_clean_bundler_env do
          Process.spawn(
            child_env, *@command,
            :chdir => @app_root,
            :in => File::NULL,
            [:out, :err] => [@log_path, "a"],
            CHILD_FD_IN => to_child_r,
            CHILD_FD_OUT => from_child_w,
            :pgroup => true
          )
        end
        @writer = Protocol::Writer.new(to_child_w)
        @reader = Protocol::Reader.new(from_child_r)
        @pid
      ensure
        # The child holds its own copies; closing ours makes EOF mean "twin is gone".
        to_child_r&.close
        from_child_w&.close
      end

      # @return [Hash] hello payload
      def await_hello
        message = read_message(@boot_timeout, waiting_for: "hello")
        if message["type"] == "error"
          payload = message["payload"]
          reap(KILL_GRACE_SECONDS)
          raise TwinBootFailed.new(
            "#{role} failed to boot: #{payload["exception_class"]}: #{payload["message"]}".sub(": : ", ": "),
            role: role, code: payload["code"], log_tail: log_tail
          )
        end
        unless message["type"] == "hello"
          terminate
          raise Protocol::ProtocolError, "#{role}: expected hello, got #{message["type"]}"
        end
        @hello = message["payload"]
      end

      # Sends a request and waits for its reply.
      # @param type [String]
      # @param payload [Hash]
      # @return [Hash] the result payload
      # @raise [TwinRequestFailed] the twin answered with an error
      def request(type, payload, timeout: @request_timeout)
        id = format("c-%06d", @next_id += 1)
        begin
          @writer.write(Protocol::Message.build(id: id, type: type, payload: payload))
        rescue Errno::EPIPE, IOError
          raise crashed("#{role} closed its protocol pipe")
        end

        reply = read_message(timeout, waiting_for: "reply to #{type} #{id}")
        unless reply["reply_to"] == id
          terminate
          raise Protocol::ProtocolError, "#{role}: reply_to #{reply["reply_to"].inspect} does not match #{id}"
        end
        if reply["type"] == "error"
          p = reply["payload"]
          raise TwinRequestFailed.new("#{role}: #{p["code"]}: #{p["message"]}", role: role, code: p["code"])
        end
        reply["payload"]
      end

      # @param session [Hash] the protocol session object (see {Doubletrack::Session#to_payload})
      # @param options [Hash] e.g. {"perform_jobs" => true}
      # @return [Hash] result payload ({"session_id", "traces"})
      def run_session(session, options = {})
        request("run_session", {"session" => session, "options" => options})
      end

      # Asks this twin to build the snapshot template (docs/design/replay.md#snapshots).
      # @return [Hash] {"template_path", "bytes", "sha256", "tables"}
      def prepare_snapshot(template_path:, seed:, seeds: false)
        request("prepare_snapshot", {"template_path" => File.expand_path(template_path),
                                     "seed" => seed, "seeds" => seeds})
      end

      # Asks the twin to exit; kills it if it doesn't.
      # @return [Process::Status, nil]
      def stop(timeout: 10)
        return @status if @status || @pid.nil?

        begin
          request("shutdown", {}, timeout: timeout)
        rescue Doubletrack::Error
          # fall through to reaping/killing
        end
        reap(timeout) || terminate
        @status
      ensure
        close_pipes
      end

      def alive?
        return false if @pid.nil? || @status

        _, status = Process.wait2(@pid, Process::WNOHANG)
        if status
          @status = status
          false
        else
          true
        end
      rescue Errno::ECHILD
        false
      end

      # Last lines of the twin's log, for error messages.
      # @return [String]
      def log_tail
        return "" unless File.exist?(@log_path)

        File.readlines(@log_path, chomp: true).last(LOG_TAIL_LINES).join("\n")
      end

      private

      def child_env
        {
          "BUNDLE_GEMFILE" => @gemfile,
          "RUBYOPT" => nil,
          "RUBYLIB" => nil,
          "RAILS_ENV" => "doubletrack",
          "RACK_ENV" => "doubletrack",
          "DATABASE_URL" => "sqlite3:#{@database_path}",
          "SECRET_KEY_BASE" => SECRET_KEY_BASE,
          "DOUBLETRACK_ROLE" => role,
          "DOUBLETRACK_FD_IN" => CHILD_FD_IN.to_s,
          "DOUBLETRACK_FD_OUT" => CHILD_FD_OUT.to_s,
          "DOUBLETRACK_WORK_DIR" => @work_dir,
          "DOUBLETRACK_LOG" => @log_path
        }.merge(@extra_env)
      end

      # Always go through Bundler.with_unbundled_env, even when the coordinator itself was
      # not started under Bundler: a parent `bundle exec` may still have exported GEM_HOME,
      # GEM_PATH, RUBYLIB, etc. (with BUNDLER_ORIG_* copies of the originals), and those
      # would point the twin at the wrong gems (RISKS R1). `require "bundler"` loads
      # Bundler's API only; it does not set up or activate any bundle.
      def with_clean_bundler_env(&block)
        require "bundler"
        Bundler.with_unbundled_env(&block)
      end

      def read_message(timeout, waiting_for:)
        @reader.read(timeout: timeout)
      rescue Protocol::ReadTimeout
        terminate
        raise TwinTimeout.new("#{role} did not send #{waiting_for} within #{timeout}s; killed it",
          role: role, log_tail: log_tail)
      rescue Protocol::Closed
        raise crashed("#{role} exited while we waited for #{waiting_for}")
      end

      def crashed(message)
        status = reap(KILL_GRACE_SECONDS) || terminate
        detail = if status.nil? then "unknown status"
        elsif status.signaled? then "killed by signal #{status.termsig}"
        else "exit status #{status.exitstatus}"
        end
        TwinCrashed.new("#{message} (#{detail})", role: role, log_tail: log_tail)
      end

      # Waits up to `timeout` seconds for the process to exit.
      def reap(timeout)
        return @status if @status

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          _, status = Process.wait2(@pid, Process::WNOHANG)
          return @status = status if status
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.02
        end
      rescue Errno::ECHILD
        nil
      end

      # TERM the twin's process group, then KILL after a grace period.
      def terminate
        return @status if @status

        signal_group("TERM")
        reap(KILL_GRACE_SECONDS) || begin
          signal_group("KILL")
          reap(KILL_GRACE_SECONDS)
        end
      end

      def signal_group(signal)
        Process.kill(signal, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def close_pipes
        @writer&.close
        @reader&.close
      end
    end
  end
end
