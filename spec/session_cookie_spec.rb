# frozen_string_literal: true

require "spec_helper"

# #286: on oe.witzman.de a login answered 200 but the next request had no
# session. Production marks the cookie Secure; behind Apache/Traefik the app
# sees plain http (no X-Forwarded-Proto: https) and rack-session then writes no
# Set-Cookie at all.
RSpec.describe "session cookie behind a TLS-terminating proxy (#286)" do
  include Rack::Test::Methods

  # Stands in for POST /login and GET /me: the session handling is the
  # middleware's, the routes only set and read session[:account].
  let(:inner) do
    lambda do |env|
      session = env["rack.session"]
      if env["REQUEST_METHOD"] == "POST"
        session[:account] = "anna"
        [200, { "content-type" => "text/plain" }, ["ok"]]
      else
        [200, { "content-type" => "text/plain" }, [session[:account].to_s]]
      end
    end
  end
  let(:secret) { "s" * 64 }
  let(:options) { Oe::SessionCookie.options(production: true) }
  let(:app) { Rack::Session::Cookie.new(inner, { secret: secret }.merge(options)) }

  # What the app sees behind the proxy: plain http, the proxy's private address.
  let(:behind_proxy) { { "HTTP_HOST" => "oe.witzman.de", "REMOTE_ADDR" => "172.18.0.2" } }

  def set_cookie = last_response.headers["set-cookie"].to_s

  def login(env = {})
    post "http://oe.witzman.de/login", {}, behind_proxy.merge(env)
  end

  describe "the bug: secure: true alone" do
    let(:options) { Oe::SessionCookie.options(production: true).except(:assume_ssl) }

    it "writes no cookie for a request that looks like http, so the session is lost" do
      login
      expect(last_response.status).to eq(200)
      expect(set_cookie).not_to include("oe.session=")
    end

    it "writes it only when the proxy says https" do
      login("HTTP_X_FORWARDED_PROTO" => "https")
      expect(set_cookie).to include("oe.session=")
    end
  end

  describe "the fix: production options" do
    it "write the Secure, HttpOnly, SameSite=Lax cookie without X-Forwarded-Proto" do
      login
      expect(set_cookie).to include("oe.session=")
      expect(set_cookie.downcase).to include("secure", "httponly", "samesite=lax")
    end

    it "keep the session on the next request (the browser sends the cookie back over https)" do
      login
      cookie = set_cookie[/oe\.session=[^;]+/]
      get "http://oe.witzman.de/me", {}, behind_proxy.merge("HTTP_COOKIE" => cookie)
      expect(last_response.body).to eq("anna")
    end

    it "still work when the proxy does say https" do
      login("HTTP_X_FORWARDED_PROTO" => "https")
      expect(set_cookie).to include("oe.session=")
    end
  end

  it "test/development use a plain cookie (no Secure, no assume_ssl)" do
    expect(Oe::SessionCookie.options(production: false)).to include(secure: false, assume_ssl: false)
  end

  it "is what app.rb hands to Rack::Session::Cookie" do
    entry = Sinatra::Application.middleware.find { |klass, *| klass == Rack::Session::Cookie }
    opts = entry[1].last
    expect(opts).to include(Oe::SessionCookie.options(production: false))
    expect(opts[:secret]).to be_a(String)
  end
end

RSpec.describe "login rate limit behind the proxy (#286)" do
  include AppHelper

  let(:limit) { Sinatra::Application.settings.login_limit }
  let(:traefik) { "172.18.0.2" }

  def failed_login(xff)
    post "/login", JSON.generate(login: "nobody", password: "wrong-password"),
         "HTTP_HOST" => "127.0.0.1", "CONTENT_TYPE" => "application/json",
         "REMOTE_ADDR" => traefik, "HTTP_X_FORWARDED_FOR" => xff
    last_response.status
  end

  before do
    Sinatra::Application.set :store, Oe::Store.new(":memory:")
    limit.max.times { limit.fail!("203.0.113.5") }
  end

  it "keys on the client address the proxy appended, not on the proxy" do
    expect(failed_login("203.0.113.5")).to eq(429)
    expect(failed_login("198.51.100.7")).to eq(401)
  end

  it "ignores addresses a client prepends itself" do
    expect(failed_login("198.51.100.7, 203.0.113.5")).to eq(429)
  end

  it "allows 30 failed logins per address and window" do
    expect(limit.max).to eq(30)
  end
end
