# frozen_string_literal: true

require "spec_helper"

RSpec.describe "registration with invite code and login (#208)" do
  let(:host) { { "HTTP_HOST" => "127.0.0.1" } }
  let(:valid) { { name: "Anna Lee", email: "Anna@Example.test", password: "correct-horse", code: "sesame" } }

  around do |ex|
    old = ENV["OE_INVITE_CODE"]
    ENV["OE_INVITE_CODE"] = "sesame"
    ex.run
  ensure
    old ? ENV["OE_INVITE_CODE"] = old : ENV.delete("OE_INVITE_CODE")
  end

  before { Sinatra::Application.set :store, Oe::Store.new(":memory:") }

  def store = Sinatra::Application.settings.store

  def post_json(path, body)
    post path, JSON.generate(body), host.merge("CONTENT_TYPE" => "application/json")
    JSON.parse(last_response.body)
  end

  def register(overrides = {})
    post_json("/register", valid.merge(overrides))
  end

  describe "POST /register" do
    it "registers, logs in and answers with id and name only" do
      body = register
      expect(last_response.status).to eq(201)
      expect(body.keys.sort).to eq(%w[id name])
      expect(body["name"]).to eq("Anna Lee")
      expect(last_response.headers["set-cookie"]).to include("oe.session=")
      get "/me"
      expect(JSON.parse(last_response.body)).to eq(body)
    end

    it "accepts form-encoded bodies too" do
      post "/register", valid, host
      expect(last_response.status).to eq(201)
    end

    it "stores only a salted hash, never the password" do
      register
      row = store.account_by_login("anna@example.test", "")
      expect(row["email"]).to eq("anna@example.test")
      expect(row["password_hash"]).to start_with("scrypt$")
      expect(row["password_hash"]).not_to include("correct-horse")
      register(name: "Other", email: "other@example.test")
      expect(store.account_by_login("other@example.test", "")["password_hash"]).not_to eq(row["password_hash"])
    end

    it "refuses a wrong or missing invite code and creates nothing" do
      [register(code: "nope"), register(code: nil), register(code: ["sesame"])].each do |body|
        expect(last_response.status).to eq(403)
        expect(body["error"]).to eq("invalid_invite")
      end
      expect(store.account_by_login("anna@example.test", "")).to be_nil
    end

    it "refuses every registration when no invite code is configured" do
      ENV.delete("OE_INVITE_CODE")
      register(code: "")
      expect(last_response.status).to eq(403)
      register(code: nil)
      expect(last_response.status).to eq(403)
    end

    it "does not echo the invite code or any password in a response" do
      body = register(code: "nope")
      expect(last_response.body).not_to include("sesame")
      expect(body.to_s).not_to include("nope")
      register
      expect(last_response.body).not_to include("sesame", "correct-horse", "scrypt")
    end

    it "says plainly when the name is taken (case-insensitive)" do
      register
      body = register(name: "anna  LEE", email: "other@example.test")
      expect([last_response.status, body["error"]]).to eq([409, "name_taken"])
    end

    it "gives no hint that an e-mail is registered" do
      register
      body = register(name: "Someone Else", email: "ANNA@example.test")
      expect([last_response.status, body["error"]]).to eq([409, "registration_failed"])
      expect(last_response.body).not_to match(/e-?mail/i)
      expect(last_response.body).not_to include("anna")
    end

    it "rejects empty, short and overlong passwords" do
      ["", nil, "short", "x" * 201, 12_345_678].each do |pw|
        body = register(password: pw)
        expect([last_response.status, body["error"]]).to eq([422, "invalid_password"])
      end
      expect(store.account_by_login("anna@example.test", "")).to be_nil
    end

    it "rejects bad names and e-mails" do
      ["", "A", "x" * 31, "Bad\u0001Name", "a@b.test", nil].each do |name|
        expect(register(name: name)["error"]).to eq("invalid_name")
      end
      ["", "nope", "a@b", "a b@c.test", nil].each do |email|
        expect(register(email: email)["error"]).to eq("invalid_email")
      end
    end

    it "survives a malformed JSON body" do
      post "/register", "{nope", host.merge("CONTENT_TYPE" => "application/json")
      expect(last_response.status).to eq(403)
    end

    it "rate-limits guessing the invite code" do
      10.times { register(code: "wrong") }
      expect(last_response.status).to eq(403)
      body = register(code: "sesame")
      expect([last_response.status, body["error"]]).to eq([429, "rate_limited"])
    end
  end

  describe "POST /login" do
    before do
      register
      post "/logout", {}, host
    end

    it "logs in with the e-mail (any case) or the name" do
      ["anna@example.test", "ANNA@example.test", "Anna Lee", "anna lee"].each do |login|
        post_json("/login", { login: login, password: "correct-horse" })
        expect(last_response.status).to eq(200), "login #{login}"
        get "/me"
        expect(JSON.parse(last_response.body)["name"]).to eq("Anna Lee")
        post "/logout", {}, host
      end
    end

    it "refuses a wrong password, an unknown login and an empty body alike" do
      [{ login: "anna@example.test", password: "wrong-password" },
       { login: "nobody@example.test", password: "correct-horse" },
       { login: "Anna Lee", password: "" },
       {}].each do |creds|
        body = post_json("/login", creds)
        expect([last_response.status, body["error"]]).to eq([401, "invalid_login"])
      end
      get "/me"
      expect(last_response.status).to eq(401)
    end

    it "rate-limits password guessing" do
      Sinatra::Application.settings.login_limit.max.times { post_json("/login", { login: "Anna Lee", password: "wrong-password" }) }
      body = post_json("/login", { login: "Anna Lee", password: "correct-horse" })
      expect([last_response.status, body["error"]]).to eq([429, "rate_limited"])
    end

    it "logs out" do
      post_json("/login", { login: "Anna Lee", password: "correct-horse" })
      post "/logout", {}, host
      get "/me"
      expect(last_response.status).to eq(401)
    end
  end

  describe "session guard" do
    it "rejects /games*, /map and /me without a session in the one error format" do
      %w[/games /me /map].each do |path|
        get path
        expect(last_response.status).to eq(401)
        expect(JSON.parse(last_response.body)).to include("error" => "login_required", "message" => a_kind_of(String))
      end
    end

    it "lets a registered session pass" do
      register
      get "/games"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("games" => [])
    end

    it "no longer has the fixed-account endpoints" do
      post "/accounts", { code: "sesame" }, host
      expect(last_response.status).to eq(404)
      post_json("/login", { account: "alice", code: "sesame" })
      expect(last_response.status).to eq(401)
    end
  end

  describe "two accounts, then login (#286)" do
    it "logs each in by name and by e-mail in case and whitespace variants, in one browser" do
      register
      post "/logout", "", host
      bob = register(name: "Bob", email: "bob@example.test", password: "another-secret")
      expect(last_response.status).to eq(201)
      post "/logout", "", host
      [["anna lee", "correct-horse"], ["  Anna   LEE ", "correct-horse"], ["anna@example.test", "correct-horse"],
       [" ANNA@EXAMPLE.TEST ", "correct-horse"], ["bob", "another-secret"], ["Bob@Example.test", "another-secret"]].each do |login, pw|
        post_json("/login", { login: login, password: pw })
        expect(last_response.status).to eq(200), "#{login.inspect} should log in"
      end
      expect(bob["name"]).to eq("Bob")
      post_json("/login", { login: "Bob", password: "correct-horse" })
      expect(last_response.status).to eq(401)
    end
  end
end
