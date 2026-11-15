# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "GET /healthz" do
  it "answers 200 with the ok status" do
    get "/healthz"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["status"]).to eq("ok")
    expect(body["build"]).to eq(Oe::BuildId.compute)
    expect(body["build"]).to match(/\A\h{12}\z/)
  end

  it "reports the roadmap version from VERSION and the engine revision (#271)" do
    get "/healthz"
    body = JSON.parse(last_response.body)
    expect(body["version"]).to eq(File.read(File.join(Oe::BuildId::ROOT, "VERSION")).strip)
    expect(body["version"]).to match(/\A\d+\.\d+\.\d+(-dev)?\z/)
    expect(body["engine"]).to eq(Oe::GameSession.engine_rev)
    expect(body["engine"]).to end_with("+#{body['build']}")
  end

  it "reports a hash of the shipped frontend bundle as web_build (#284)" do
    get "/healthz"
    body = JSON.parse(last_response.body)
    expect(body["web_build"]).to eq(Oe::BuildId.web_value)
    expect(body["web_build"]).to match(/\A\h{12}\z/).or be_nil
  end

  it "does not change build when only the frontend changes, but web_build does (#284)" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "web/dist"))
      File.write(File.join(dir, "web/dist/main.js"), "a")
      File.write(File.join(dir, "web/dist/main.js.map"), "m1")
      first = Oe::BuildId.compute_web(dir)
      File.write(File.join(dir, "web/dist/main.js.map"), "m2")
      expect(Oe::BuildId.compute_web(dir)).to eq(first) # source maps are ignored
      File.write(File.join(dir, "web/dist/main.js"), "b")
      expect(Oe::BuildId.compute_web(dir)).not_to eq(first)
    end
    expect(Oe::BuildId.compute_web(Dir.mktmpdir)).to be_nil # no bundle, no hash
  end

  it "reports the database as writable" do
    get "/healthz"
    expect(JSON.parse(last_response.body)["db"]).to eq("writable")
  end

  it "answers 503 and degraded when the database cannot be written" do
    allow(app.settings.store).to receive(:writable?).and_return(false)
    get "/healthz"
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body)).to include("status" => "degraded", "db" => "not writable")
  end

  it "still rejects unknown hosts" do
    get "/healthz", {}, { "HTTP_HOST" => "evil.example" }
    expect(last_response.status).to eq(403)
  end
end
