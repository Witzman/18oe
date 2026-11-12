# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GET /healthz" do
  it "answers 200 with the ok status" do
    get "/healthz"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq('{"status":"ok"}')
  end

  it "still rejects unknown hosts" do
    get "/healthz", {}, { "HTTP_HOST" => "evil.example" }
    expect(last_response.status).to eq(403)
  end
end
