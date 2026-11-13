# frozen_string_literal: true

ENV["APP_ENV"] = "test"
ENV["RACK_ENV"] = "test"
# The engine logs every action at DEBUG unless told otherwise (3 = ERROR).
ENV["ENGINE_LOG_LEVEL"] ||= "3"

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

# Test accounts (#208): id "alice", name "Alice", e-mail alice@example.test,
# password "pw-alice-1234" -- created straight in the store (registration is
# covered by accounts_spec).
module AccountHelper
  def seed_accounts(store, *ids)
    hash = Oe::Accounts.hash_password(TEST_PASSWORD)
    ids.flatten.each do |id|
      store.create_account(id: id, name: id.capitalize, email: "#{id}@example.test", password_hash: hash)
    end
  end
end

TEST_PASSWORD = "test-password-1"

RSpec.configure do |config|
  config.include AccountHelper
  config.before do
    Sinatra::Application.settings.register_limit.reset!
    Sinatra::Application.settings.login_limit.reset!
    Sinatra::Application.settings.lookup_limit.reset!
  end
  config.include AppHelper
end
