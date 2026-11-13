# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Oe
  class ScriptGame
    # A logged-in HTTP client. Both kinds answer `call(verb, path, body = nil)`
    # with [status, parsed JSON or nil, seconds].
    module Clients
      def self.timed
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, body = yield
        [status, body, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
      end

      def self.parse(text)
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      # In process through Rack::Test (the spec).
      class Rack
        def initialize(app, host: "127.0.0.1")
          require "rack/test"
          @host = host
          @session = Class.new { include ::Rack::Test::Methods }.new
          @session.define_singleton_method(:app) { app }
        end

        def call(verb, path, body = nil)
          env = { "HTTP_HOST" => @host }
          env["CONTENT_TYPE"] = "application/json" if body
          Clients.timed do
            @session.public_send(verb, path, body ? JSON.generate(body) : {}, env)
            [@session.last_response.status, Clients.parse(@session.last_response.body)]
          end
        end
      end

      # Against a running instance over real HTTP, with its own cookie jar.
      class Net
        def initialize(base)
          @uri = URI(base)
          @cookies = {}
          @http = ::Net::HTTP.new(@uri.host, @uri.port)
          @http.use_ssl = @uri.scheme == "https"
          @http.read_timeout = 120
          @http.keep_alive_timeout = 30
        end

        def call(verb, path, body = nil)
          klass = ::Net::HTTP.const_get(verb.to_s.capitalize)
          req = klass.new(path)
          req["Content-Type"] = "application/json" if body
          req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ") unless @cookies.empty?
          req.body = JSON.generate(body) if body
          Clients.timed do
            res = @http.request(req)
            Array(res.get_fields("set-cookie")).each do |line|
              name, value = line.split(";", 2).first.split("=", 2)
              @cookies[name] = value
            end
            [res.code.to_i, Clients.parse(res.body)]
          end
        end
      end
    end
  end
end
