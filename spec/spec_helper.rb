# frozen_string_literal: true

ENV["APP_ENV"] = "test"
ENV["RACK_ENV"] = "test"

require "rack/test"
require "rspec"

# Sinatra classic style only auto-starts a server when app.rb is the
# executed file ($0), so requiring it here does not boot anything.
require_relative "../app"

module AppHelper
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  # rack-test defaults to Host: example.org, which host_authorization rejects.
  # Use an allowed host instead of loosening the setting in app.rb.
  def get(uri, params = {}, env = {}, &block)
    super(uri, params, { "HTTP_HOST" => "127.0.0.1" }.merge(env), &block)
  end
end

RSpec.configure do |config|
  config.include AppHelper
  config.disable_monkey_patching!
end
