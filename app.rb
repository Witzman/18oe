# frozen_string_literal: true

# Walking skeleton. No game logic yet — this proves the container builds,
# starts, and answers a healthcheck (which also reports the build id, so a
# deploy can be verified from outside). See 18oe-workshop#2/#3 and
# notes/reference/infrastructure-plan.md for what comes next.

# The container starts `ruby app.rb` without -Ilib; the engine is required as "engine".
$LOAD_PATH.unshift(File.join(__dir__, "lib")) unless $LOAD_PATH.include?(File.join(__dir__, "lib"))

require "sinatra"
require "json"
require "securerandom"
require_relative "lib/oe/build_id"
require_relative "lib/oe/accounts"
require_relative "lib/oe/games_api"

set :bind, "0.0.0.0"
set :port, (ENV["PORT"] || 80).to_i
set :host_authorization, { permitted_hosts: ["oe.witzman.de", "127.0.0.1", "localhost"] }

# Session cookie. SESSION_SECRET comes from the environment (Dokploy), never
# the repo. Outside test/dev the app refuses to start without it and without
# the shared access code, because the site is open on the internet.
dev_mode = %w[test development].include?(ENV["APP_ENV"] || ENV["RACK_ENV"] || "production")
unless dev_mode
  %w[SESSION_SECRET OE_ACCESS_CODE].each do |key|
    abort "#{key} must be set outside test/dev" if ENV[key].to_s.empty?
  end
end
use Rack::Session::Cookie,
    key: "oe.session",
    secret: ENV["SESSION_SECRET"].to_s.empty? ? SecureRandom.hex(32) : ENV["SESSION_SECRET"],
    same_site: :lax,
    httponly: true,
    secure: !dev_mode

# One SQLite store per process (Puma runs a single process; see #34). Tests
# use an in-memory database; DATABASE_PATH overrides the default /data volume.
set :store, Oe::Store.new(dev_mode && !ENV["DATABASE_PATH"] ? ":memory:" : (ENV["DATABASE_PATH"] || Oe::Store::DEFAULT_PATH))

helpers do
  def json(status_code, payload)
    status status_code
    content_type :json
    JSON.generate(payload)
  end

  # {error: <machine code>, message: <human text>} — the one error format.
  def api_error(status_code, code, message)
    json status_code, error: code, message: message
  end

  def current_account
    id = session[:account]
    id && Oe::Accounts.find(id)
  end

  def request_params
    return params unless request.media_type == "application/json"

    JSON.parse(request.body.read)
  rescue JSON::ParserError
    {}
  end
end

before "/games*" do
  halt api_error(401, "login_required", "login required") unless current_account
end

post "/login" do
  data = request_params
  account = Oe::Accounts.find(data["account"])
  unless account && Oe::Accounts.access_ok?(data["code"])
    session.clear
    halt api_error(401, "invalid_login", "invalid account or access code")
  end
  session.clear
  session[:account] = account["id"]
  json 200, account
end

post "/logout" do
  session.clear
  json 200, ok: true
end

get "/me" do
  account = current_account
  account ? json(200, account) : api_error(401, "login_required", "login required")
end

get "/accounts" do
  json 200, accounts: Oe::Accounts.all.map { |id, name| { id: id, name: name } }
end

register Oe::GamesApi

not_found do
  api_error 404, "not_found", "no such endpoint"
end

error do
  api_error 500, "internal_error", "internal error"
end

get "/healthz" do
  content_type :json
  JSON.generate(status: "ok", build: Oe::BuildId.value)
end
