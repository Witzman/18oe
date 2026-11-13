# frozen_string_literal: true

require "spec_helper"

# The browser app (#40): static serving and the contract between the server JSON
# and web/types.ts.
RSpec.describe "web frontend (#40)" do
  let(:dist) { File.expand_path("../web/dist", __dir__) }

  describe "static files" do
    it "serves the built app at / and its assets" do
      skip "web/dist not built (cd web && npm run build)" unless File.file?(File.join(dist, "index.html"))

      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('<div id="app">')
      get "/main.js"
      expect(last_response.status).to eq(200)
      get "/theme.css"
      expect(last_response.status).to eq(200)
      # Theme tokens (#95): generated from web/themes/*.json, one rule per theme.
      get "/themes.css"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(':root[data-theme="brett"]', ':root[data-theme="atlas"]')
    end

    it "serves theme fonts locally and references no foreign host (#98)" do
      skip "web/dist not built (cd web && npm run build)" unless File.file?(File.join(dist, "index.html"))

      get "/fonts.css"
      expect(last_response.status).to eq(200)
      files = last_response.body.scan(%r{url\((/fonts/[^)]+\.woff2)\)}).flatten
      expect(files.size).to eq(16)
      files.each do |path|
        get path
        expect(last_response.status).to eq(200), "#{path} answered #{last_response.status}"
        expect(last_response.body.bytesize).to be > 1000
      end
      %w[/ /theme.css /themes.css /fonts.css].each do |path|
        get path
        expect(last_response.body).not_to match(%r{(https?:)?//[a-z0-9.-]+\.[a-z]{2,}}i), "#{path} references a foreign host"
      end
      %w[/fonts/SOURCES.md /fonts/LICENSES/barlow-OFL.txt].each do |path|
        get path
        expect(last_response.status).to eq(200)
      end
    end

    it "never serves sources, package files or node_modules" do
      %w[/main.ts /package.json /package-lock.json /build.mjs /api.ts /node_modules/esbuild/package.json /view-keys.json
         /themes/brett.json /themes/schema.ts
         /../web/package.json /%2e%2e/web/package.json].each do |path|
        get path
        expect(last_response.status).to eq(404), "#{path} answered #{last_response.status}"
      end
    end

    it "keeps /games behind the login" do
      get "/games"
      expect(last_response.status).to eq(401)
    end
  end

  describe "view model contract" do
    let(:keys) { JSON.parse(File.read(File.expand_path("../web/view-keys.json", __dir__))) }

    before do
      Sinatra::Application.set :store, Oe::Store.new(":memory:")
      seed_accounts(Sinatra::Application.settings.store, %w[alice])
    end

    def post_json(path, body)
      post path, JSON.generate(body), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1" }
      JSON.parse(last_response.body)
    end

    it "matches the key sets declared in web/view-keys.json (mirrors web/types.ts)" do
      post_json("/login", { login: "alice", password: TEST_PASSWORD })
      game = post_json("/games", { seats: [{ kind: "human", account_id: "alice" }, { kind: "bot" }, { kind: "bot" }], seed: 1 })

      expect(game.keys.sort).to eq(%w[id seats seq state status viewer])
      state = game["state"]
      expect(state.keys.sort).to eq(keys["state"])
      expect(state["meta"].keys.sort).to eq(keys["meta"])
      expect(state["meta"]["round"].keys.sort).to eq(keys["round"])
      expect(state["meta"]["phase"].keys.sort).to eq(keys["phase"])
      expect(state["players"].first.keys.sort).to eq(keys["player"])
      expect(state["corporations"].first.keys.sort).to eq(keys["corporation"])
      expect(state["prompt"].keys.sort).to eq(keys["prompt"])
      expect(state["prompt"]["context"].keys.sort).to eq(keys["context"])
      expect(state["depot"].keys.sort).to eq(keys["depot"])
      expect(state["market"].keys.sort).to eq(keys["market"])
      # A new game starts in the auction (#120).
      expect(state["auction"].keys.sort).to eq(keys["auction"])
      expect(state["auction"]["cards"].first.keys.sort).to eq(keys["auction_card"])
    end
  end
end
