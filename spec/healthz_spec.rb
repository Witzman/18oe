# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GET /healthz" do
  it "answers 200 with the ok status" do
    get "/healthz"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["status"]).to eq("ok")
    expect(body["build"]).to eq(Oe::BuildId.compute)
    expect(body["build"]).to match(/\A\h{12}\z/)
  end

  it "still rejects unknown hosts" do
    get "/healthz", {}, { "HTTP_HOST" => "evil.example" }
    expect(last_response.status).to eq(403)
  end
end
