# frozen_string_literal: true

require "net/http"

module Doubletrack
  module Recorder
    # Replaces Net::HTTP's network access inside a twin (ADR 0012). Once installed:
    # * `Net::HTTP#connect` never opens a socket;
    # * `Net::HTTP#request` answers from a matching stub, or with a synthetic 503
    #   `x-doubletrack: blocked`, and records the call into the current sink.
    #
    # Standard library only. Installed before the app boots.
    module HttpInterceptor
      BLOCKED_STATUS = 503

      # Prepended to Net::HTTP.
      module NetHTTPPatch
        def request(req, body = nil, &block)
          response = HttpInterceptor.handle(self, req, body)
          yield response if block
          response
        end

        private

        # Never touch the network. `start` still marks the connection as started,
        # and `finish` copes with a nil socket.
        def connect
          nil
        end
      end

      @stubs = [].freeze
      @sink = nil

      class << self
        def install!
          Net::HTTP.prepend(NetHTTPPatch) unless installed?
        end

        def installed?
          Net::HTTP.ancestors.include?(NetHTTPPatch)
        end

        # Records calls made inside the block into `sink` (an Array), answering from `stubs`.
        # @param stubs [Array<Hash>] see docs/design/protocol.md (http_stubs)
        # @param sink [Array<Hash>]
        def recording(stubs:, sink:)
          previous = [@stubs, @sink]
          @stubs = Array(stubs)
          @sink = sink
          yield
        ensure
          @stubs, @sink = previous
        end

        # @api private
        def handle(http, req, body)
          url = url_for(http, req)
          stub = @stubs.find { |s| match?(s, req.method, url) }
          canned = stub ? stub_response(stub) : blocked_response
          entry = {
            "method" => req.method,
            "url" => url,
            "request_headers" => req.to_hash,
            "request_body" => request_body(req, body),
            "stubbed" => !stub.nil?,
            "response" => canned
          }
          if @sink
            @sink << entry
          else
            warn "doubletrack: outbound HTTP outside a replayed request was blocked: #{req.method} #{url}"
          end
          net_http_response(canned)
        end

        # @api private
        def match?(stub, method, url)
          return false if stub["method"] && stub["method"].to_s.upcase != method
          return false unless stub["url"]

          (stub["match"] == "prefix") ? url.start_with?(stub["url"]) : url == stub["url"]
        end

        private

        def url_for(http, req)
          scheme = http.use_ssl? ? "https" : "http"
          default_port = http.use_ssl? ? 443 : 80
          port = (http.port == default_port) ? "" : ":#{http.port}"
          "#{scheme}://#{http.address}#{port}#{req.path}"
        end

        def request_body(req, body)
          data = body || req.body
          data&.to_s&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        end

        def stub_response(stub)
          headers = (stub["headers"] || {}).to_h { |k, v| [k.to_s.downcase, Array(v).map(&:to_s)] }
          {"status" => Integer(stub.fetch("status", 200)), "headers" => headers, "body" => stub["body"].to_s}
        end

        def blocked_response
          {"status" => BLOCKED_STATUS, "headers" => {"x-doubletrack" => ["blocked"]}, "body" => ""}
        end

        def net_http_response(canned)
          code = canned["status"].to_s
          klass = Net::HTTPResponse::CODE_TO_OBJ[code] || Net::HTTPResponse
          response = klass.new("1.1", code, "")
          canned["headers"].each { |name, values| values.each { |v| response.add_field(name, v) } }
          response.instance_variable_set(:@body, canned["body"])
          response.instance_variable_set(:@read, true)
          response
        end
      end
    end
  end
end
