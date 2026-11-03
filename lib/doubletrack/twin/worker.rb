# frozen_string_literal: true

module Doubletrack
  module Twin
    # The request loop inside a twin. Boots the app, sends hello, then answers one
    # request at a time until shutdown or EOF.
    class Worker
      ENVIRONMENTS_DIR = File.expand_path("environments", __dir__)
      HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD].freeze

      def initialize(input:, output:, started_at:, role: ENV.fetch("DOUBLETRACK_ROLE", "unknown"), app_root: Dir.pwd)
        @reader = Protocol::Reader.new(input)
        @writer = Protocol::Writer.new(output)
        @started_at = started_at
        @role = role
        @app_root = app_root
        @counter = 0
      end

      def run
        begin
          boot_app
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "doubletrack twin: boot failed: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(20).join("\n")}"
          send_message(Protocol::Message.error(id: next_id, code: "boot_failed", message: e.message, exception: e))
          exit 1
        end

        send_message(Protocol::Message.build(id: next_id, type: "hello", payload: hello_payload))
        loop { handle(read_request) }
      rescue Protocol::Closed
        exit 0 # coordinator went away; nothing left to do
      end

      private

      # Boots Rails in the `doubletrack` environment without touching app files (ADR 0009).
      def boot_app
        # Block outbound HTTP before any app code runs (ADR 0012).
        require_relative "../recorder/http_interceptor"
        Recorder::HttpInterceptor.install!

        require File.join(@app_root, "config", "application")
        Rails.application.paths["config/environments"] << ENVIRONMENTS_DIR
        require File.join(@app_root, "config", "environment")
        require "action_dispatch/testing/integration"
        require_relative "../recorder/recorder"
        load_schema_stopgap
      end

      # M0 stopgap so DB-backed pages render: load db/schema.rb into this twin's private,
      # empty database. Replaced by prepare_snapshot (template + copy) in M2.
      def load_schema_stopgap
        schema = File.join(@app_root, "db", "schema.rb")
        return unless defined?(ActiveRecord::Base) && File.exist?(schema)

        ActiveRecord::Schema.verbose = false
        load schema
      end

      def hello_payload
        {
          "role" => @role,
          "pid" => Process.pid,
          "ruby_version" => RUBY_VERSION,
          "ruby_platform" => RUBY_PLATFORM,
          "rails_version" => Rails.version,
          "rails_env" => Rails.env.to_s,
          "app" => {"name" => Rails.application.class.module_parent_name, "root" => Rails.root.to_s},
          "bundle_gemfile" => ENV["BUNDLE_GEMFILE"],
          "boot_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round(1)
        }
      end

      def read_request
        @reader.read
      rescue Protocol::SchemaMismatch => e
        send_message(Protocol::Message.error(id: next_id, code: "schema_mismatch", message: e.message))
        nil
      rescue Protocol::UnknownType => e
        send_message(Protocol::Message.error(id: next_id, code: "unknown_type", message: e.message))
        nil
      rescue Protocol::ProtocolError => e
        send_message(Protocol::Message.error(id: next_id, code: "bad_message", message: e.message))
        nil
      end

      def handle(message)
        return if message.nil?

        case message["type"]
        when "run_session" then reply(message, run_session(message["payload"]["session"]))
        when "shutdown"
          reply(message, {"ok" => true})
          exit 0
        when "prepare_snapshot"
          reply_error(message, "not_implemented", "prepare_snapshot arrives in M2")
        else
          reply_error(message, "unknown_type", "twins do not accept #{message["type"]} messages")
        end
      rescue => e
        warn "doubletrack twin: #{message && message["type"]} failed: #{e.class}: #{e.message}"
        reply_error(message, "session_failed", e.message, exception: e)
      end

      # One integration session per replay session, so cookies carry across requests.
      # Each request is recorded into a trace (docs/formats/trace.md). M2 adds
      # snapshots, determinism controls and recorded timing.
      def run_session(session)
        reset_state
        recorder = Recorder::Recorder.new(http_stubs: session["http_stubs"])
        integration = ActionDispatch::Integration::Session.new(Rails.application)
        traces = Array(session["requests"]).each_with_index.map do |request, index|
          validate_request(request)
          recorder.capture(index, request) { perform(integration, request) }
        end
        {"session_id" => session["id"], "traces" => traces}
      end

      # Per-session reset of in-memory state (docs/design/recorder.md). The database
      # is not reset until M2 snapshots.
      def reset_state
        Rails.cache.clear
        ActionMailer::Base.deliveries.clear if defined?(ActionMailer::Base)
        return unless defined?(ActiveJob::Base)

        adapter = ActiveJob::Base.queue_adapter
        adapter.enqueued_jobs.clear if adapter.respond_to?(:enqueued_jobs)
        adapter.performed_jobs.clear if adapter.respond_to?(:performed_jobs)
      end

      def validate_request(request)
        method = request.fetch("method", "GET").upcase
        raise ArgumentError, "unsupported HTTP method #{method}" unless HTTP_METHODS.include?(method)
        raise ArgumentError, "request path missing" unless request["path"].is_a?(String)
      end

      # @return [ActionDispatch::TestResponse]
      def perform(integration, request)
        options = {params: request["params"], headers: request["headers"]}
        options[:as] = request["as"].to_sym if request["as"]
        integration.public_send(request.fetch("method", "GET").downcase, request["path"], **options)
        integration.response
      end

      def reply(request, payload)
        send_message(Protocol::Message.build(id: next_id, type: "result", reply_to: request["id"], payload: payload))
      end

      def reply_error(request, code, text, exception: nil)
        send_message(Protocol::Message.error(id: next_id, code: code, message: text,
          reply_to: request && request["id"], exception: exception))
      end

      def send_message(message)
        @writer.write(message)
      end

      def next_id
        format("t-%06d", @counter += 1)
      end
    end
  end
end
