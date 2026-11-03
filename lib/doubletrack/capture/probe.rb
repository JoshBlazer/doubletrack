# frozen_string_literal: true

require "json"
require_relative "record"

module Doubletrack
  module Capture
    # The part of capture that lives in the app's test process (ADR 0025). Loaded by
    # boot.rb; inert unless DOUBLETRACK_CAPTURE_DIR is set. Never changes arguments or
    # return values, and never raises into a test.
    module Probe
      TEST_KEY = :doubletrack_capture_test

      # Prepended to ActionDispatch::Integration::Session.
      module SessionHook
        def process(method, path, **options)
          record = Probe.safely { Record.build(method: method, path: path, **options) }
          raised = nil
          begin
            super
          rescue Exception => e # rubocop:disable Lint/RescueException -- observed, then re-raised untouched
            raised = e
            raise
          ensure
            Probe.safely { Probe.write(record, self, raised) } if record
          end
        end
      end

      # Included into ActionDispatch::IntegrationTest (Minitest) for test names.
      module MinitestNaming
        def before_setup
          location = Probe.safely { self.class.instance_method(name).source_location }
          Thread.current[TEST_KEY] = {"test" => "#{self.class.name}##{name}",
                                      "location" => location && Probe.relative(location.join(":"))}
          super
        end

        def after_teardown
          super
        ensure
          Thread.current[TEST_KEY] = nil
        end
      end

      @mutex = Mutex.new
      @installed = false

      class << self
        def register
          ActiveSupport.on_load(:action_dispatch_integration_test) do
            include Doubletrack::Capture::Probe::MinitestNaming

            Doubletrack::Capture::Probe.install!
          end
          ActiveSupport.on_load(:after_initialize) do
            require "action_dispatch/testing/integration"
            Doubletrack::Capture::Probe.install!
          end
        end

        def install!
          @mutex.synchronize do
            return if @installed

            ActionDispatch::Integration::Session.prepend(SessionHook)
            @installed = true
          end
        end

        def write(record, session, raised)
          status = raised ? nil : safely { session.response&.status }
          line = record.merge(current_test(session)).merge("status" => status, "raised" => raised&.class&.name)
          @mutex.synchronize do
            reopen_for_pid
            line["pid"] = Process.pid
            line["seq"] = (@seq += 1)
            text = begin
              JSON.generate(line)
            rescue JSON::GeneratorError, EncodingError => e
              JSON.generate(line.slice("test", "test_id", "location", "pid", "seq", "method").merge(
                "path" => line["path"].to_s.scrub, "unsupported" => "request is not valid JSON/UTF-8: #{e.class}"
              ))
            end
            @file.write(text, "\n")
          end
        end

        def current_test(session)
          info = Thread.current[TEST_KEY]
          return info if info

          if defined?(::RSpec) && ::RSpec.respond_to?(:current_example) && (example = ::RSpec.current_example)
            return {"test" => example.full_description, "test_id" => example.id.to_s, "location" => relative(example.location.to_s)}
          end
          {"test" => "integration-session-#{session.object_id}", "location" => nil}
        end

        def relative(path)
          path.delete_prefix("#{Dir.pwd}/").delete_prefix("./")
        end

        def safely
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException -- capture must never break a test
          warn "doubletrack capture: #{e.class}: #{e.message}" if ENV["DOUBLETRACK_CAPTURE_DEBUG"]
          nil
        end

        private

        # One file per process: forked parallel test workers each get their own.
        def reopen_for_pid
          return if @pid == Process.pid

          @pid = Process.pid
          @seq = 0
          @file = File.open(File.join(ENV.fetch("DOUBLETRACK_CAPTURE_DIR"), "capture-#{@pid}.jsonl"), "a")
          @file.sync = true
        end
      end
    end
  end
end
