# frozen_string_literal: true

require "spec_helper"

RSpec.describe "POC password reset by e-mail (#282)" do
  let(:host) { { "HTTP_HOST" => "127.0.0.1" } }

  before do
    Sinatra::Application.set :store, Oe::Store.new(":memory:")
    Sinatra::Application.settings.reset_limit.reset!
    Oe::Accounts.register(store, name: "witzman", email: "Witz@Example.test", password: "old-password-1")
  end

  def store = Sinatra::Application.settings.store

  def post_json(path, body)
    post path, JSON.generate(body), host.merge("CONTENT_TYPE" => "application/json")
    JSON.parse(last_response.body)
  end

  it "answers with a new password once; the old one stops working, the new one logs in" do
    body = post_json("/reset-password", { email: " witz@example.TEST " })
    expect(last_response.status).to eq(200)
    expect(body.keys).to eq(["password"])
    expect(body["password"].length).to eq(14)

    post_json("/login", { login: "witzman", password: "old-password-1" })
    expect(last_response.status).to eq(401)
    post_json("/login", { login: "witzman", password: body["password"] })
    expect(last_response.status).to eq(200)
  end

  it "generates a different password each time" do
    a = post_json("/reset-password", { email: "witz@example.test" })["password"]
    b = post_json("/reset-password", { email: "witz@example.test" })["password"]
    expect(a).not_to eq(b)
  end

  it "does not accept a name instead of an e-mail address" do
    post_json("/reset-password", { email: "witzman" })
    expect(last_response.status).to eq(422)
    expect(JSON.parse(last_response.body)["error"]).to eq("invalid_email")
  end

  it "says so for an unknown address and changes nothing" do
    post_json("/reset-password", { email: "nobody@example.test" })
    expect(last_response.status).to eq(422)
    expect(JSON.parse(last_response.body)["error"]).to eq("unknown_email")
    post_json("/login", { login: "witzman", password: "old-password-1" })
    expect(last_response.status).to eq(200)
  end

  it "rejects non-string input without an error page" do
    post_json("/reset-password", { email: ["a@b.test"] })
    expect(last_response.status).to eq(422)
  end

  it "is rate limited per client address" do
    5.times { post_json("/reset-password", { email: "nobody@example.test" }) }
    post_json("/reset-password", { email: "witz@example.test" })
    expect(last_response.status).to eq(429)
    post_json("/login", { login: "witzman", password: "old-password-1" })
    expect(last_response.status).to eq(200)
  end
end
