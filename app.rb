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
require_relative "lib/oe/version"
require_relative "lib/oe/accounts"
require_relative "lib/oe/session_cookie"
require_relative "lib/oe/games_api"
require_relative "lib/oe/map_data"

set :bind, "0.0.0.0"
set :port, (ENV["PORT"] || 80).to_i
# The browser app: only web/dist is ever served (sources, node_modules and
# package files stay out of reach). Build it with `cd web && npm run build`.
set :public_folder, File.join(__dir__, "web", "dist")
set :static, true
set :host_authorization, { permitted_hosts: ["oe.witzman.de", "127.0.0.1", "localhost"] }

# Session cookie. SESSION_SECRET comes from the environment (Dokploy), never
# the repo. Outside test/dev the app refuses to start without it and without
# the invite code (#208), because the site is open on the internet.
dev_mode = %w[test development].include?(ENV["APP_ENV"] || ENV["RACK_ENV"] || "production")
unless dev_mode
  %w[SESSION_SECRET OE_INVITE_CODE].each do |key|
    abort "#{key} must be set outside test/dev" if ENV[key].to_s.empty?
  end
end
# Secure cookie also when the proxy chain does not say https (#286), see
# lib/oe/session_cookie.rb.
use Rack::Session::Cookie,
    secret: ENV["SESSION_SECRET"].to_s.empty? ? SecureRandom.hex(32) : ENV["SESSION_SECRET"],
    **Oe::SessionCookie.options(production: !dev_mode)

# One SQLite store per process (Puma runs a single process; see #34). Tests
# use an in-memory database; DATABASE_PATH overrides the default /data volume.
set :store, Oe::Store.new(dev_mode && !ENV["DATABASE_PATH"] ? ":memory:" : (ENV["DATABASE_PATH"] || Oe::Store::DEFAULT_PATH))

# Bots: :async (background threads) in production, :off in tests unless a spec
# switches to :inline. OE_BOTS=off|async|inline overrides.
set :bot_mode, (ENV["OE_BOTS"] || (ENV["APP_ENV"] == "test" ? "off" : "async")).to_sym

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
    id && Oe::Accounts.find(settings.store, id)
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

before "/map" do
  halt api_error(401, "login_required", "login required") unless current_account
end

# Guessing limits per client address (#208): wrong invite codes on /register,
# wrong passwords on /login. In memory, one Puma process. Only failures count.
# request.ip (#286): Rack's default. A private/loopback REMOTE_ADDR (the
# Traefik container) counts as a trusted proxy; then the right-most public
# entry of X-Forwarded-For is used, i.e. the one a proxy appended, so a client
# cannot dodge the limit by sending its own header. If the proxy chain sends
# no X-Forwarded-For (or appends a public proxy address last), all clients
# share one bucket; that is unverified live, so failed logins get 30 per 15
# minutes (typos of a whole table of friends), still far too few to guess a
# password. Invite-code guessing stays at 10.
set :register_limit, Oe::Accounts::RateLimit.new(max: 10, window: 900)
set :login_limit, Oe::Accounts::RateLimit.new(max: 30, window: 900)
# POC password reset (#282): every request counts, not only failures.
set :reset_limit, Oe::Accounts::RateLimit.new(max: 5, window: 900)
# Naming players by name/e-mail when creating a game (#212), per creator account.
set :lookup_limit, Oe::Accounts::RateLimit.new(max: 20, window: 900)

helpers do
  def too_many!
    halt api_error(429, "rate_limited", "too many attempts, try again later")
  end
end

post "/register" do
  limit = settings.register_limit
  too_many! if limit.blocked?(request.ip)
  data = request_params
  data = {} unless data.is_a?(Hash)
  unless Oe::Accounts.invite_ok?(data["code"])
    limit.fail!(request.ip)
    halt api_error(403, "invalid_invite", "invalid invite code")
  end
  begin
    account = Oe::Accounts.register(settings.store, name: data["name"], email: data["email"], password: data["password"])
  rescue Oe::Accounts::Invalid => e
    status_code = e.code == "name_taken" || e.code == "registration_failed" ? 409 : 422
    halt api_error(status_code, e.code, e.message)
  end
  session.clear
  session[:account] = account["id"]
  json 201, account
end

# login: e-mail or name.
post "/login" do
  limit = settings.login_limit
  too_many! if limit.blocked?(request.ip)
  data = request_params
  data = {} unless data.is_a?(Hash)
  account = Oe::Accounts.authenticate(settings.store, data["login"], data["password"])
  unless account
    limit.fail!(request.ip)
    session.clear
    halt api_error(401, "invalid_login", "invalid login or password")
  end
  session.clear
  session[:account] = account["id"]
  json 200, account
end

# POC password reset (#282): e-mail only, the new password is shown once, no mail.
# Known risk, accepted for the POC: whoever knows an address can take the account (#283 replaces this).
post "/reset-password" do
  limit = settings.reset_limit
  too_many! if limit.blocked?(request.ip)
  limit.fail!(request.ip)
  data = request_params
  data = {} unless data.is_a?(Hash)
  email = data["email"]
  halt api_error(422, "invalid_email", "e-mail address looks invalid") unless email.is_a?(String) && Oe::Accounts.normalize_email(email).match?(Oe::Accounts::EMAIL_FORMAT)
  password = Oe::Accounts.reset_password(settings.store, email)
  halt api_error(422, "unknown_email", "no account with this e-mail address") unless password
  session.clear
  json 200, password: password
end

post "/logout" do
  session.clear
  json 200, ok: true
end

get "/me" do
  account = current_account
  account ? json(200, account) : api_error(401, "login_required", "login required")
end

register Oe::GamesApi

# The fixed map (#43): changes only with the engine revision, so the ETag is
# derived from it and the browser revalidates cheaply (304). private: it sits
# behind the login.
get "/map" do
  rev = Oe::GameSession.engine_rev
  etag "map-#{Oe::MapData::SCHEMA}-#{rev}"
  cache_control :private, :no_cache
  content_type :json
  Oe::MapData.json(rev)
end

# A restart in the middle of a bot chain: pick it up again.
Oe::GamesApi.runner_for(settings.store).resume_all if settings.bot_mode == :async

not_found do
  api_error 404, "not_found", "no such endpoint"
end

error do
  api_error 500, "internal_error", "internal error"
end

get "/" do
  index = File.join(settings.public_folder, "index.html")
  halt api_error(404, "not_found", "frontend not built") unless File.file?(index)

  send_file index
end

get "/healthz" do
  content_type :json
  # status/build as before (#41); version = roadmap version from VERSION, engine = engine
  # revision that new games are stamped with (#271). Fields are only ever added.
  # A database that cannot be written makes the app useless: 503 + "degraded", so Docker's
  # healthcheck and Dokploy see it (the volume mount is the usual culprit).
  db_ok = settings.store.writable?
  status(db_ok ? 200 : 503)
  JSON.generate(status: db_ok ? "ok" : "degraded", build: Oe::BuildId.value, version: Oe::Version.value,
                engine: Oe::GameSession.engine_rev, db: db_ok ? "writable" : "not writable")
end
