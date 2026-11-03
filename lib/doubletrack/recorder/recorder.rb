# frozen_string_literal: true

require_relative "jsonable"
require_relative "http_interceptor"

module Doubletrack
  module Recorder
    TRACE_VERSION = 1

    # Records one request's response and side effects into a trace
    # (docs/formats/trace.md). Runs inside a booted twin; uses ActiveSupport.
    # Design: docs/design/recorder.md.
    class Recorder
      SQL_WRITE = /\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i
      SQL_TABLE = /\A\s*(?:INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+[`"\[]?([\w.]+)/i
      SQL_IGNORED_NAMES = ["SCHEMA"].freeze
      JOB_FIELDS = %w[job_class queue_name priority arguments scheduled_at].freeze
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
      def initialize(http_stubs: [])
        @http_stubs = Array(http_stubs)
      end

      # Runs the block (which performs one request and returns the response object)
      # and returns its trace. App exceptions are recorded, not raised.
      # @param index [Integer] position in the session
      # @param request [Hash] the request as received from the coordinator
      # @return [Hash] trace
      def capture(index, request)
        trace = empty_trace(index, request)
        mail_events = []
        started = monotonic
        subscriptions = subscribe(trace, mail_events)
        begin
          HttpInterceptor.recording(stubs: @http_stubs, sink: trace["http"]) do
            trace["response"] = serialize_response(yield)
          end
        rescue => e
          trace["exception"] = {
            "class" => e.class.name,
            "message" => e.message.to_s[0, 1000],
            "backtrace" => Array(e.backtrace).first(10)
          }
        ensure
          subscriptions.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
        end
        trace["duration_ms"] = ((monotonic - started) * 1000).round(2)
        read_back_cache_values(trace["cache"])
        trace["mail"] = mail_events.map { |event| mail_entry(event) }
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
          "response" => nil,
          "exception" => nil,
          "sql_writes" => [],
          "jobs" => [],
          "mail" => [],
          "cache" => [],
          "http" => [],
          "duration_ms" => nil
        }
      end

      def subscribe(trace, mail_events)
        subs = []
        subs << ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          entry = sql_entry(payload)
          trace["sql_writes"] << entry if entry
        end
        JOB_EVENTS.each do |name|
          subs << ActiveSupport::Notifications.subscribe(name) do |*, payload|
            event = name.split(".").first
            jobs = payload[:jobs] || [payload[:job]]
            jobs.compact.each { |job| trace["jobs"] << job_entry(event, job) }
          end
        end
        subs << ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |*, payload|
          mail_events << payload.slice(:mailer, :message_id, :to, :from, :cc, :bcc, :subject)
        end
        CACHE_EVENTS.each do |name, op|
          subs << ActiveSupport::Notifications.subscribe(name) do |*, payload|
            cache_keys(payload[:key]).each { |key| trace["cache"] << {"op" => op, "key" => key} }
          end
        end
        subs
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

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
