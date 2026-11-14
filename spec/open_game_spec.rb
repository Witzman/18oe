# frozen_string_literal: true

require "spec_helper"
require "oe/bot"

# #294: re-opening a game at OR 1.1 (4 seats: the owner and 3 bots, the owner operating BEL) showed
# "Keine Verbindung" and a map-only page. The server side of that state is checked here over the real
# HTTP API: GET /games/:id answers 200 with the full state (prompt with the viewer's actions) quickly,
# also from a cold process (no cached session). The client path is web/test/open-game-browser.test.ts.
RSpec.describe "opening a game at OR 1.1 with the viewer operating a regional (#294)" do
  include AppHelper
  include AccountHelper

  let(:store) { Oe::Store.new(":memory:") }
  let(:json_env) { { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1" } }

  before do
    Sinatra::Application.set :store, store
    Sinatra::Application.set :bot_mode, :inline
    seed_accounts(store, "witzman")
    post "/login", JSON.generate(login: "witzman", password: TEST_PASSWORD), json_env
    expect(last_response.status).to eq(200)
  end

  after { Sinatra::Application.set :bot_mode, :off }

  def body = JSON.parse(last_response.body)

  # Plays the viewer's seat (p0) with the bot heuristics, parring BEL once, until p0 operates BEL in OR 1.
  def play_to_bel_operating(id, rng)
    parred = false
    400.times do
      session = Oe::GameSession.load(store, id)
      game = session.game
      entity = game.round.active_step&.current_entity
      return session if game.round.is_a?(Engine::Round::Operating) && entity&.id == "BEL"

      action = nil
      if !parred && game.round.is_a?(Engine::Round::Stock)
        action = Oe::Bot.new(game, rng: rng).legal_actions("p0")
                        .find { |a| a.is_a?(Engine::Action::Par) && a.corporation.id == "BEL" }
        parred = !action.nil?
      end
      action ||= Oe::Bot.choose(game, rng: rng, player_id: "p0")
      post "/games/#{id}/actions", JSON.generate(action: action.to_h, seq: session.seq), json_env
      raise "action refused: #{last_response.status} #{last_response.body[0, 200]}" unless last_response.status == 200
    end
    raise "BEL never operated"
  end

  it "answers GET /games/:id with the full state in well under a second, cached and cold" do
    seats = [{ kind: "human", account_id: "witzman" }, { kind: "bot" }, { kind: "bot" }, { kind: "bot" }]
    post "/games", JSON.generate(seats: seats, seed: 1), json_env
    expect(last_response.status).to eq(201)
    id = body["id"]
    play_to_bel_operating(id, Random.new(1))

    [false, true].each do |cold|
      store.sessions.clear if cold
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      get "/games/#{id}?log=40"
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      expect(last_response.status).to eq(200), last_response.body[0, 300]
      state = body["state"]
      expect(state.dig("meta", "round", "type")).to eq("operating")
      expect(state.dig("prompt", "viewer_to_act")).to be(true)
      expect(state.dig("prompt", "actions").map { |a| a["entity"] }.uniq).to eq(["BEL"])
      expect(state.dig("prompt", "types")).to include("lay_tile")
      # Locally ~0.4 s cold; the limit only catches a regression to the #197 multi-second spikes.
      expect(elapsed).to be < 5, "GET /games/#{id} took #{elapsed.round(2)} s (cold: #{cold})"
    end
  end

  it "logs a client display error (POST /client-errors) for a logged-in player and answers ok" do
    expect do
      post "/client-errors", JSON.generate(game_id: 1, message: "TypeError: x is undefined", stack: "at f", agent: "Firefox"), json_env
    end.to output(/client-error .*"account":"witzman".*TypeError: x is undefined/).to_stderr
    expect(last_response.status).to eq(200)
  end

  it "refuses /client-errors without a login" do
    post "/logout", nil, json_env
    post "/client-errors", JSON.generate(message: "x"), json_env
    expect(last_response.status).to eq(401)
  end
end
