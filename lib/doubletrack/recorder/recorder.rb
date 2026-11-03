# frozen_string_literal: true

require_relative "jsonable"
require_relative "http_interceptor"
require_relative "../twin/clock"

module Doubletrack
  module Recorder
    TRACE_VERSION = 2

    # Records one request's response and side effects into a trace
    # (docs/formats/trace.md), then performs the jobs it enqueued (ADR 0014) and records
    # theirs. Runs inside a booted twin; uses ActiveSupport. Design: docs/design/recorder.md,
    # docs/design/replay.md.
    class Recorder
      SQL_WRITE = /\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i
      SQL_TABLE = /\A\s*(?:INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+[`"\[]?([\w.]+)/i
      SQL_IGNORED_NAMES = ["SCHEMA"].freeze
      JOB_FIELDS = %w[job_class queue_name priority arguments scheduled_at].freeze
      CHANNELS = %w[sql_writes jobs mail cache http].freeze
      MAX_PERFORMED_JOBS = 25
      CACHE_EVENTS = {
        "cache_write.active_support" => "write",
        "cache_write_multi.active_support" => "write",
        "cache_delete.active_support" => "delete",
        "cache_delete_multi.active_support" => "delete",
        "cache_increment.active_support" => "increment",
        "cache_decrement.active_support" => "decrement"
      }.freeze
      JOB_EVENTS = %w[enqueue.active_job enqueue_at.active_job enqueue_all.active_job].freeze

      # @param http_stubs [Array<Hash>]
      # @param perform_jobs [Boolean] perform enqueued jobs after each request (ADR 0014)
      def initialize(http_stubs: [], perform_jobs: false)
        @http_stubs = Array(http_stubs)
        @perform_jobs = perform_jobs
      end

      # Runs the block (which performs one request and returns the response object)
      # and returns its trace. App exceptions are recorded, not raised.
      # @param index [Integer] position in the session
      # @param request [Hash] the request as received from the coordinator
      # @param session_reader [#call, nil] returns the Rack session Hash after the request
      # @return [Hash] trace
      def capture(index, request, session_reader: nil)
        trace = empty_trace(index, request)
        started = monotonic
        enqueued = []
        record(trace, enqueued, request: true) do
          trace["response"] = serialize_response(yield)
          trace["session"] = Jsonable.call(session_reader&.call)
        end
        trace["duration_ms"] = ((monotonic - started) * 1000).round(2)
        perform_jobs(trace, enqueued) if @perform_jobs
        trace
      end

      private

      def empty_trace(index, request)
        {
          "trace_version" => TRACE_VERSION,
          "request" => {
            "index" => index,
            "method" => request.fetch("method", "GET").upcase,
            "path" => request["path"],
            "params" => Jsonable.call(request["params"] || {}),
            "headers" => Jsonable.call(request["headers"] || {})
          },
          "route" => nil,
          "time" => now_iso,
          "response" => nil,
          "exception" => nil,
          "session" => nil,
          "sql_writes" => [],
          "jobs" => [],
          "mail" => [],
          "cache" => [],
          "http" => [],
          "deprecations" => [],
          "performed_jobs" => [],
          "duration_ms" => nil
        }
      end

      # Subscribes for the duration of the block, writing channels into `target`.
      # Enqueued job objects are appended to `enqueued` (for inline performing).
      def record(target, enqueued, request: false)
        mail_events = []
        subscriptions = subscribe(target, mail_events, enqueued, request: request)
        begin
          HttpInterceptor.recording(stubs: @http_stubs, sink: target["http"]) { yield }
        rescue => e
          target["exception"] = {
            "class" => e.class.name,
            "message" => e.message.to_s[0, 1000],
            "backtrace" => Array(e.backtrace).first(10)
          }
        ensure
          subscriptions.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
        end
        read_back_cache_values(target["cache"])
        target["mail"] = mail_events.map { |event| mail_entry(event) }
      end

      def subscribe(target, mail_events, enqueued, request:)
        subs = []
        subs << ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          entry = sql_entry(payload)
          target["sql_writes"] << entry if entry
        end
        JOB_EVENTS.each do |name|
          subs << ActiveSupport::Notifications.subscribe(name) do |*, payload|
            event = name.split(".").first
            jobs = payload[:jobs] || [payload[:job]]
            jobs.compact.each do |job|
              target["jobs"] << job_entry(event, job)
              enqueued << job
            end
          end
        end
        subs << ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |*, payload|
          mail_events << payload.slice(:mailer, :message_id, :to, :from, :cc, :bcc, :subject)
        end
        CACHE_EVENTS.each do |name, op|
          subs << ActiveSupport::Notifications.subscribe(name) do |*, payload|
            cache_keys(payload[:key]).each { |key| target["cache"] << {"op" => op, "key" => key} }
          end
        end
        if request
          subs << ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*, payload|
            target["route"] ||= route_entry(payload)
          end
          subs << ActiveSupport::Notifications.subscribe("deprecation.rails") do |*, payload|
            target["deprecations"] << {"message" => payload[:message].to_s[0, 500], "gem" => payload[:gem_name].to_s}
          end
        end
        subs
      end

      # Performs jobs in enqueue order, including jobs enqueued by jobs (ADR 0014).
      def perform_jobs(trace, queue)
        performed = 0
        until queue.empty?
          if performed >= MAX_PERFORMED_JOBS
            trace["performed_jobs_truncated"] = true
            break
          end
          job = queue.shift
          performed += 1
          trace["performed_jobs"] << perform_job(job, queue)
        end
      end

      def perform_job(job, queue)
        serialized = job.serialize
        entry = {"job_class" => serialized["job_class"], "queue_name" => serialized["queue_name"],
                 "arguments" => Jsonable.call(serialized["arguments"]), "performed_at" => nil, "exception" => nil}
        CHANNELS.each { |c| entry[c] = [] }
        run_at = [Twin::Clock.frozen, job.respond_to?(:scheduled_at) && job.scheduled_at&.to_r].compact.max
        perform = -> {
          entry["performed_at"] = now_iso
          record(entry, queue) { ActiveJob::Base.execute(serialized) }
        }
        run_at ? Twin::Clock.freeze_at(Time.at(run_at)) { perform.call } : perform.call
        entry
      end

      def route_entry(payload)
        request = payload[:request]
        pattern = request.respond_to?(:route_uri_pattern) ? request.route_uri_pattern : nil
        {
          "verb" => (request&.request_method || payload[:method]).to_s,
          "path" => pattern&.to_s,
          "controller" => payload[:controller].to_s.delete_suffix("Controller").gsub("::", "/")
            .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase,
          "action" => payload[:action].to_s
        }
      end

      def sql_entry(payload)
        return nil if payload[:cached] || SQL_IGNORED_NAMES.include?(payload[:name])

        sql = payload[:sql].to_s
        statement = sql[SQL_WRITE, 1]
        return nil unless statement

        {
          "statement" => statement.upcase,
          "table" => sql[SQL_TABLE, 1],
          "name" => payload[:name],
          "sql" => sql,
          "binds" => binds(payload[:binds])
        }
      end

      def binds(list)
        Array(list).each_with_object({}) do |attribute, result|
          next unless attribute.respond_to?(:name)

          value = attribute.respond_to?(:value_for_database) ? attribute.value_for_database : attribute.value
          result[attribute.name.to_s] = Jsonable.call(value)
        end
      end

      def job_entry(event, job)
        serialized = begin
          job.serialize
        rescue => e
          {"job_class" => job.class.name, "arguments" => "#<unserializable: #{e.class}>"}
        end
        entry = {"event" => event}
        JOB_FIELDS.each { |field| entry[field] = Jsonable.call(serialized[field]) }
        entry["scheduled_at"] ||= Jsonable.call(job.scheduled_at) if job.respond_to?(:scheduled_at)
        entry
      end

      def cache_keys(key)
        case key
        when Hash then key.keys.map(&:to_s)
        when Array then key.map(&:to_s)
        else [key.to_s]
        end
      end

      # Done after unsubscribing so these reads are not recorded.
      def read_back_cache_values(entries)
        entries.each do |entry|
          next unless entry["op"] == "write"

          entry["value"] = Jsonable.call(Rails.cache.read(entry["key"], namespace: nil))
        end
      end

      def mail_entry(event)
        message = defined?(ActionMailer::Base) &&
          ActionMailer::Base.deliveries.reverse.find { |m| m.message_id == event[:message_id] }
        {
          "mailer" => event[:mailer].to_s,
          "to" => Array(message&.to || event[:to]),
          "from" => Array(message&.from || event[:from]),
          "cc" => Array(message&.cc || event[:cc]),
          "bcc" => Array(message&.bcc || event[:bcc]),
          "subject" => (message&.subject || event[:subject]).to_s,
          "text_body" => message && part_body(message, "text/plain"),
          "html_body" => message && part_body(message, "text/html"),
          "attachments" => message ? message.attachments.map(&:filename) : []
        }
      end

      def part_body(message, mime_type)
        part = (mime_type == "text/html") ? message.html_part : message.text_part
        part ||= message if message.mime_type == mime_type || (message.mime_type.nil? && mime_type == "text/plain")
        part&.decoded
      end

      def serialize_response(response)
        {
          "status" => response.status,
          "headers" => response.headers.to_h.transform_keys { |k| k.to_s.downcase },
          "body" => Protocol::Message.encode_body(response.body)
        }
      end

      def now_iso
        Time.now.getutc.iso8601(6)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
