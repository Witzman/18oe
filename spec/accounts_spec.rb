# frozen_string_literal: true

require "spec_helper"

RSpec.describe "accounts and session (#33)" do
  around do |ex|
    old = ENV.to_h.slice("OE_ACCESS_CODE", "OE_ACCOUNTS")
    ENV["OE_ACCESS_CODE"] = "sesame"
    ENV.delete("OE_ACCOUNTS")
    ex.run
  ensure
    ENV.delete("OE_ACCESS_CODE")
    ENV.delete("OE_ACCOUNTS")
    old.each { |k, v| ENV[k] = v }
  end

  def login(account, code)
    post "/login", { account: account, code: code }, { "HTTP_HOST" => "127.0.0.1" }
  end

  it "parses OE_ACCOUNTS" do
    expect(Oe::Accounts.parse("a:Anna Lee, b:Bo,c")).to eq("a" => "Anna Lee", "b" => "Bo", "c" => "c")
  end

  it "rejects /games* without a session" do
    get "/games"
    expect(last_response.status).to eq(401)
  end

  it "rejects /me without a session" do
    get "/me"
    expect(last_response.status).to eq(401)
  end

  it "rejects a wrong access code and sets no session" do
    login("alice", "nope")
    expect(last_response.status).to eq(401)
    get "/me"
    expect(last_response.status).to eq(401)
  end

  it "rejects an unknown account" do
    login("mallory", "sesame")
    expect(last_response.status).to eq(401)
  end

  it "logs in, sets a cookie, and /me returns the account" do
    login("alice", "sesame")
    expect(last_response.status).to eq(200)
    expect(last_response.headers["set-cookie"]).to include("oe.session=")
    get "/me"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("id" => "alice", "name" => "Alice")
  end

  it "lets a logged-in session pass the /games* guard (404, not 401)" do
    login("bob", "sesame")
    get "/games"
    expect(last_response.status).to eq(404)
  end

  it "logs out" do
    login("alice", "sesame")
    post "/logout", {}, { "HTTP_HOST" => "127.0.0.1" }
    get "/me"
    expect(last_response.status).to eq(401)
  end

  it "reads accounts from OE_ACCOUNTS" do
    ENV["OE_ACCOUNTS"] = "x:Xavier"
    login("x", "sesame")
    expect(last_response.status).to eq(200)
    login("alice", "sesame")
    expect(last_response.status).to eq(401)
  end

  it "accepts a JSON login body" do
    post "/login", JSON.generate(account: "alice", code: "sesame"),
         { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1" }
    expect(last_response.status).to eq(200)
  end
end
