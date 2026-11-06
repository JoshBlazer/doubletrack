# frozen_string_literal: true

require_relative "../recorder/jsonable" # standard library only
require_relative "../rails_label" # standard library only
require_relative "loaded_gems" # standard library only

module Doubletrack
  module Twin
    # The request loop inside a twin. Boots the app, sends hello, then answers one
    # request at a time until shutdown or EOF.
    class Worker
      ENVIRONMENTS_DIR = File.expand_path("environments", __dir__)
      HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD].freeze
      DEFAULT_STARTED_AT = "2026-01-01T00:00:00Z"

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
      # The working database stays empty until a snapshot is restored (docs/design/replay.md).
      def boot_app
        # Block outbound HTTP and install the clock before any app code runs (ADR 0012, 0015).
        require_relative "../recorder/http_interceptor"
        require_relative "clock"
        Recorder::HttpInterceptor.install!
        Clock.install!

        require File.join(@app_root, "config", "application")
        require_relative "database"
        @database = Database.configure!(role: @role, work_dir: ENV.fetch("DOUBLETRACK_WORK_DIR", Dir.pwd),
          app_database_url: ENV["DOUBLETRACK_APP_DATABASE_URL"])
        Rails.application.paths["config/environments"] << ENVIRONMENTS_DIR
        require File.join(@app_root, "config", "environment")
        require "action_dispatch/testing/integration"
        require_relative "../recorder/recorder"
        require_relative "snapshot"
      end

      def hello_payload
        {
          "role" => @role,
          "pid" => Process.pid,
          "ruby_version" => RUBY_VERSION,
          "ruby_platform" => RUBY_PLATFORM,
          "rails_version" => Rails.version,
          "rails_revision" => Doubletrack::RailsLabel.loaded_revision,
          "gems" => Doubletrack::Twin::LoadedGems.call,
          "database" => @database,
          "rails_env" => Rails.env.to_s,
          "app" => {"name" => Rails.application.class.module_parent_name, "root" => Rails.root.to_s},
          "bundle_gemfile" => ENV["BUNDLE_GEMFILE"],
          "session_cookie" => session_cookie_name,
          "routes" => routes,
          "boot_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round(1)
        }
      end

      def session_cookie_name
        Rails.application.config.session_options[:key]&.to_s
      rescue
        nil
      end

      # Application routes, for coverage. Internal routes and /rails/ routes are excluded.
      def routes
        Rails.application.routes.routes.filter_map do |route|
          next if route.respond_to?(:internal) && route.internal

          path = route.path.spec.to_s
          next if path.start_with?("/rails/") || route.defaults[:controller].nil?

          {"verb" => route.verb.to_s, "path" => path, "name" => route.name,
           "controller" => route.defaults[:controller].to_s, "action" => route.defaults[:action].to_s}
        end
      end

      def read_request
        @reader.read
      rescue Protocol::SchemaMismatch => e
        send_message(Protocol::Message.error(id: next_id, code: "schema_mismatch", message: e.message))
        nil
      rescue Protocol::UnknownType => e
        send_message(Protocol::Message.error(id: next_id, code: "unknown_type", message: e.message))
        nil
      rescue Protocol::FrameTooLarge => e
        # The rest of that frame is still in the pipe; the stream can't be resynchronized.
        send_message(Protocol::Message.error(id: next_id, code: "bad_message", message: e.message))
        exit 1
      rescue Protocol::ProtocolError => e
        send_message(Protocol::Message.error(id: next_id, code: "bad_message", message: e.message))
        nil
      end

      def handle(message)
        return if message.nil?

        payload = message["payload"]
        case message["type"]
        when "run_session" then reply(message, run_session(payload["session"], payload["options"] || {}))
        when "prepare_snapshot" then reply(message, prepare_snapshot(payload))
        when "shutdown"
          cleanup_database
          reply(message, {"ok" => true})
          exit 0
        else
          reply_error(message, "unknown_type", "twins do not accept #{message["type"]} messages")
        end
      rescue => e
        warn "doubletrack twin: #{message && message["type"]} failed: #{e.class}: #{e.message}"
        reply_error(message, "session_failed", e.message, exception: e)
      end

      # Builds the snapshot template with rand seeded. The clock is deliberately NOT frozen:
      # loading schema.rb validates migration timestamps against "now" (Rails 7.2+), and
      # a session's started_at may predate the app's migrations. The template is built
      # once and shared by every twin, so real time here cannot cause A/B differences
      # (docs/design/replay.md#snapshots).
      def prepare_snapshot(payload)
        Kernel.srand(Integer(payload.fetch("seed", 0)))
        snapshot.build(payload.fetch("template_path"), seeds: payload["seeds"] == true, fixtures: payload["fixtures"] == true,
          seed: Integer(payload.fetch("seed", 0)))
      end

      # PostgreSQL twins drop their databases and templates (ADR 0037). A failure here is
      # logged, never sent: the run's results are already complete.
      def cleanup_database
        snapshot.cleanup if defined?(Snapshot)
      rescue => e
        warn "doubletrack twin: database cleanup failed: #{e.class}: #{e.message}"
      end

      # One integration session per replay session, so cookies carry across requests.
      # Each request is recorded into a trace (docs/formats/trace.md) with the clock frozen
      # at started_at + offset_ms (docs/design/replay.md#determinism-controls).
      def run_session(session, options)
        reset_state
        snapshot.restore(session["snapshot"]) if session["snapshot"]
        Kernel.srand(Integer(session.fetch("seed", 0)))
        started_at = Time.iso8601(session.fetch("started_at", DEFAULT_STARTED_AT))
        recorder = Recorder::Recorder.new(http_stubs: session["http_stubs"],
          perform_jobs: options.fetch("perform_jobs", true))
        integration = ActionDispatch::Integration::Session.new(Rails.application)
        session_reader = -> { integration.request&.session&.to_hash }
        traces = Array(session["requests"]).each_with_index.map do |request, index|
          validate_request(request)
          at = started_at + Rational(request.fetch("offset_ms", 1000 * index), 1000)
          Clock.freeze_at(at) do
            recorder.capture(index, request, session_reader: session_reader) { perform(integration, request) }
          end
        end
        {"session_id" => session["id"], "traces" => traces}
      end

      def snapshot
        @snapshot ||= Snapshot.new(database_path: ActiveRecord::Base.connection_db_config.database, app_root: @app_root)
      end

      # Per-session reset of in-memory state (docs/design/recorder.md).
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

      # Scrubbed first: exception messages, SQL text, headers and cache keys reach traces
      # as recorded, and one invalid UTF-8 byte would make the whole reply unsendable.
      def send_message(message)
        @writer.write(Recorder::Jsonable.scrub(message))
      end

      def next_id
        format("t-%06d", @counter += 1)
      end
    end
  end
end
