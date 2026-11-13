# frozen_string_literal: true

require "spec_helper"
require "oe/legal_actions"

RSpec.describe "games API (#36)" do
  # One logged-in browser session per account.
  class ApiClient
    include Rack::Test::Methods

    def initialize(app)
      @app = app
    end

    attr_reader :app

    def api(verb, path, body = nil)
      env = { "HTTP_HOST" => "127.0.0.1" }
      env["CONTENT_TYPE"] = "application/json" if body
      send(verb, path, body ? JSON.generate(body) : {}, env)
      parsed = begin
        JSON.parse(last_response.body)
      rescue JSON::ParserError
        nil
      end
      [last_response.status, parsed]
    end
  end

  def client_for(account)
    c = ApiClient.new(Sinatra::Application)
    status, = c.api(:post, "/login", { login: account, password: TEST_PASSWORD })
    raise "login failed for #{account}: #{status}" unless status == 200

    c
  end

  before do
    ENV.delete("OE_MAX_GAMES")
    Sinatra::Application.set :store, Oe::Store.new(":memory:")
    seed_accounts(Sinatra::Application.settings.store, %w[alice bob carol dave erin])
  end

  after do
    ENV.delete("OE_MAX_GAMES")
  end

  let(:humans) { %w[alice bob carol dave].to_h { |n| [n, client_for(n)] } }
  let(:alice) { humans["alice"] }
  let(:seats4) { %w[alice bob carol dave].map { |n| { kind: "human", account_id: n } } }

  def create_game(client, seats, seed: 1)
    client.api(:post, "/games", { seats: seats, seed: seed })
  end

  def seat_account(state, engine_id)
    # engine id "p<n>" -> account that holds seat n
    state["seats"][engine_id[1..].to_i]["account_id"]
  end

  def active_client(state)
    humans.fetch(seat_account(state, state["state"]["meta"]["active_players"].first))
  end

  describe "creating and listing" do
    it "creates a game with seats, seed and an initial view for the creator" do
      status, game = create_game(alice, seats4, seed: 7)
      expect(status).to eq(201)
      expect(game).to include("id", "status" => "active", "viewer" => "p0", "seq" => 0)
      expect(game["seats"].map { |s| s["account_id"] }).to eq(%w[alice bob carol dave])
      expect(game["state"]["meta"]["seq"]).to eq(0)
      expect(game["state"]["players"].size).to eq(4)
    end

    it "accepts bots and names them" do
      status, game = create_game(alice, [{ kind: "human", account_id: "alice" }, { kind: "bot" }, { kind: "bot" }])
      expect(status).to eq(201)
      expect(game["seats"].map { |s| s["kind"] }).to eq(%w[human bot bot])
      expect(game["seats"][1]["name"]).to eq("Bot 2")
    end

    it "lists only the games the account holds a seat in" do
      create_game(alice, seats4)
      create_game(humans["bob"], [{ kind: "human", account_id: "bob" }, { kind: "bot" }])
      _, mine = alice.api(:get, "/games")
      _, bobs = humans["bob"].api(:get, "/games")
      _, none = client_for("erin").api(:get, "/games")
      expect(mine["games"].size).to eq(1)
      expect(bobs["games"].size).to eq(2)
      expect(none["games"]).to eq([])
    end

    {
      "one seat" => [{ kind: "human", account_id: "alice" }],
      "eight seats" => Array.new(8) { |i| i.zero? ? { kind: "human", account_id: "alice" } : { kind: "bot" } },
      "duplicate account" => [{ kind: "human", account_id: "alice" }, { kind: "human", account_id: "alice" }],
      "creator without seat" => [{ kind: "human", account_id: "bob" }, { kind: "bot" }],
      "unknown account" => [{ kind: "human", account_id: "alice" }, { kind: "human", account_id: "mallory" }],
      "bad kind" => [{ kind: "human", account_id: "alice" }, { kind: "robot" }],
    }.each do |name, seats|
      it "rejects #{name} with 422" do
        status, body = create_game(alice, seats)
        expect(status).to eq(422)
        expect(body).to include("error" => "invalid_seats", "message" => a_kind_of(String))
      end
    end

    it "rejects a seat list that is not a list, and invalid JSON, with 4xx JSON" do
      expect(alice.api(:post, "/games", { seats: "x" })[0]).to eq(422)
      alice.post "/games", "{nope", { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1" }
      expect(alice.last_response.status).to eq(400)
      expect(JSON.parse(alice.last_response.body)["error"]).to eq("bad_request")
    end

    it "limits the number of active games" do
      ENV["OE_MAX_GAMES"] = "1"
      expect(create_game(alice, seats4)[0]).to eq(201)
      status, body = create_game(alice, seats4)
      expect(status).to eq(422)
      expect(body["error"]).to eq("game_limit")
    end

    it "demands a login" do
      c = ApiClient.new(Sinatra::Application)
      expect(c.api(:post, "/games", { seats: [] })[0]).to eq(401)
      expect(c.api(:get, "/games/1")[0]).to eq(401)
    end
  end

  describe "reading" do
    let!(:game) { create_game(alice, seats4)[1] }

    it "gives every account its own view; strangers see a spectator view without actions" do
      _, mine = alice.api(:get, "/games/#{game['id']}")
      _, bobs = humans["bob"].api(:get, "/games/#{game['id']}")
      _, seen = client_for("erin").api(:get, "/games/#{game['id']}")
      expect([mine["viewer"], bobs["viewer"]]).to eq(%w[p0 p1])
      expect(seen["viewer"]).to be_nil
      expect(seen["state"]["prompt"]["viewer_to_act"]).to be(false)
      expect(seen["state"]["prompt"]["actions"]).to be_empty
    end

    it "gives the acting seat its legal actions and nobody else" do
      acting = game["state"]["meta"]["active_players"].first
      humans.each_value do |c|
        _, g = c.api(:get, "/games/#{game['id']}")
        mine = g["viewer"] == acting
        expect(g["state"]["prompt"]["viewer_to_act"]).to eq(mine)
        expect(g["state"]["prompt"]["actions"].empty?).to eq(!mine)
      end
    end

    it "answers /version with just seq and status" do
      expect(alice.api(:get, "/games/#{game['id']}/version")).to eq([200, { "seq" => 0, "status" => "active" }])
    end

    it "returns 404 JSON for unknown games" do
      expect(alice.api(:get, "/games/999")[0]).to eq(404)
      expect(alice.api(:get, "/games/999/version")[0]).to eq(404)
      expect(alice.api(:get, "/games/abc")[0]).to eq(404)
      expect(alice.api(:get, "/games/999/actions")[0]).to eq(404)
      expect(alice.api(:post, "/games/999/actions", { action: {}, seq: 0 })[0]).to eq(404)
    end
  end

  describe "playing over HTTP" do
    let!(:game) { create_game(alice, seats4, seed: 3)[1] }
    let(:id) { game["id"] }

    def state_of(client)
      client.api(:get, "/games/#{id}")[1]
    end

    def offered(client)
      state_of(client)["state"]["prompt"]["actions"]
    end

    it "plays 80 random legal actions: every turn goes to the right account, seq rises, log grows" do
      rng = Random.new(5)
      80.times do |n|
        current = state_of(alice)
        client = active_client(current)
        actions = offered(client)
        expect(actions).not_to be_empty
        pick = actions.group_by { |a| a["type"] }.values.sample(random: rng).sample(random: rng)

        status, body = client.api(:post, "/games/#{id}/actions", { action: pick, seq: n })
        expect(status).to eq(200), body.inspect
        expect(body["seq"]).to eq(n + 1)
        expect(body["state"]["meta"]["seq"]).to eq(n + 1)
        expect(alice.api(:get, "/games/#{id}/version")[1]["seq"]).to eq(n + 1)
      end

      _, log = alice.api(:get, "/games/#{id}/actions")
      expect(log["actions"].map { |a| a["seq"] }).to eq((1..80).to_a)
      expect(log["actions"].map { |a| a["actor"] }.uniq - %w[alice bob carol dave]).to be_empty
      expect(log["actions"].first["payload"]).to include("type", "entity")
    end

    it "refuses an account that is not on turn (403) and changes nothing" do
      current = state_of(alice)
      acting = current["state"]["meta"]["active_players"].first
      offered_action = offered(active_client(current)).first
      other = humans.values.find { |c| state_of(c)["viewer"] != acting }

      status, body = other.api(:post, "/games/#{id}/actions", { action: offered_action, seq: 0 })
      expect(status).to eq(403)
      expect(body["error"]).to eq("not_your_turn")
      expect(alice.api(:get, "/games/#{id}/version")[1]["seq"]).to eq(0)
    end

    it "refuses a stranger without a seat (403)" do
      erin = client_for("erin")
      action = offered(active_client(state_of(alice))).first
      status, body = erin.api(:post, "/games/#{id}/actions", { action: action, seq: 0 })
      expect([status, body["error"]]).to eq([403, "forbidden"])
    end

    it "answers 409 for a stale seq" do
      client = active_client(state_of(alice))
      action = offered(client).first
      expect(client.api(:post, "/games/#{id}/actions", { action: action, seq: 0 })[0]).to eq(200)

      next_client = active_client(state_of(alice))
      next_action = offered(next_client).first
      status, body = next_client.api(:post, "/games/#{id}/actions", { action: next_action, seq: 0 })
      expect([status, body["error"]]).to eq([409, "conflict"])
      expect(alice.api(:get, "/games/#{id}/version")[1]["seq"]).to eq(1)
    end

    it "answers 422 for an invalid action and leaves the log untouched, and play continues" do
      current = state_of(alice)
      client = active_client(current)
      entity = current["state"]["meta"]["active_players"].first
      bogus = { "type" => "bid", "entity" => entity, "entity_type" => "player", "company" => "nope", "price" => 1 }

      status, body = client.api(:post, "/games/#{id}/actions", { action: bogus, seq: 0 })
      expect([status, body["error"]]).to eq([422, "rejected"])
      expect(body["message"]).to be_a(String)
      expect(alice.api(:get, "/games/#{id}/actions")[1]["actions"]).to eq([])
      expect(alice.api(:get, "/games/#{id}/version")[1]["seq"]).to eq(0)

      good = offered(client).first
      expect(client.api(:post, "/games/#{id}/actions", { action: good, seq: 0 })[0]).to eq(200)
    end

    it "refuses undo and missing/invalid parts of the body" do
      client = active_client(state_of(alice))
      entity = state_of(alice)["state"]["meta"]["active_players"].first
      undo = { "type" => "undo", "entity" => entity, "entity_type" => "player" }
      expect(client.api(:post, "/games/#{id}/actions", { action: undo, seq: 0 })[0]).to eq(422)
      expect(client.api(:post, "/games/#{id}/actions", { action: undo })[0]).to eq(400)
      expect(client.api(:post, "/games/#{id}/actions", { seq: 0 })[0]).to eq(400)
      expect(client.api(:post, "/games/#{id}/actions", { action: "x", seq: 0 })[0]).to eq(400)
      expect(client.api(:post, "/games/#{id}/actions", { action: undo, seq: "0" })[0]).to eq(400)
    end
  end

  describe "bots" do
    it "never lets a human act for a bot seat" do
      _, game = create_game(alice, [{ kind: "human", account_id: "alice" }, { kind: "bot" }], seed: 2)
      id = game["id"]
      forbidden = nil
      12.times do
        state = alice.api(:get, "/games/#{id}")[1]
        acting = state["state"]["meta"]["active_players"].first
        if state["seats"][acting[1..].to_i]["kind"] == "bot"
          # the bot is on turn: alice tries to move for it
          probe = { "type" => "pass", "entity" => acting, "entity_type" => "player" }
          forbidden = alice.api(:post, "/games/#{id}/actions", { action: probe, seq: state["seq"] })
          break
        end
        action = state["state"]["prompt"]["actions"].first
        expect(alice.api(:post, "/games/#{id}/actions", { action: action, seq: state["seq"] })[0]).to eq(200)
      end
      expect(forbidden).not_to be_nil, "the bot never became active in 12 actions"
      expect([forbidden[0], forbidden[1]["error"]]).to eq([403, "not_your_turn"])
    end
  end
end

RSpec.describe "games API with bot seats (#39)" do
  class BotApiClient
    include Rack::Test::Methods

    def app = Sinatra::Application

    def api(verb, path, body = nil)
      env = { "HTTP_HOST" => "127.0.0.1" }
      env["CONTENT_TYPE"] = "application/json" if body
      send(verb, path, body ? JSON.generate(body) : {}, env)
      [last_response.status, JSON.parse(last_response.body)]
    end
  end

  let(:alice) do
    c = BotApiClient.new
    c.post "/login", { login: "alice", password: TEST_PASSWORD }, { "HTTP_HOST" => "127.0.0.1" }
    c
  end
  let(:seats) { [{ kind: "human", account_id: "alice" }, { kind: "bot" }, { kind: "bot" }] }

  before do
    Sinatra::Application.set :store, Oe::Store.new(":memory:")
    seed_accounts(Sinatra::Application.settings.store, %w[alice])
  end

  after do
    Sinatra::Application.set :bot_mode, :off
  end

  def play_one(client, id)
    state = client.api(:get, "/games/#{id}")[1]
    action = state["state"]["prompt"]["actions"].first
    client.api(:post, "/games/#{id}/actions", { action: action, seq: state["seq"] })
  end

  it "lets the bots answer inside the request (inline): the response is back at the human" do
    Sinatra::Application.set :bot_mode, :inline
    status, game = alice.api(:post, "/games", { seats: seats, seed: 2 })
    expect(status).to eq(201)
    expect(game["state"]["meta"]["active_players"]).to eq([game["viewer"]])
    expect(game["state"]["prompt"]["viewer_to_act"]).to be(true)

    before_seq = game["seq"]
    status, after = play_one(alice, game["id"])
    expect(status).to eq(200)
    expect(after["seq"]).to be >= before_seq + 3 # the human's move and both bots' replies
    expect(after["state"]["prompt"]["viewer_to_act"]).to be(true)

    _, log = alice.api(:get, "/games/#{game['id']}/actions")
    expect(log["actions"].map { |a| a["actor"] }.uniq.sort).to eq(%w[alice bot:1 bot:2])
    expect(log["incidents"]).to eq([])
  end

  it "lets the bots answer in the background (async): the human sees their moves via polling" do
    Sinatra::Application.set :bot_mode, :async
    runner = Oe::GamesApi.runner_for(Sinatra::Application.settings.store)
    _, game = alice.api(:post, "/games", { seats: seats, seed: 2 })
    id = game["id"]
    expect(runner.wait_idle(id, timeout: 60)).to be(true)

    status, = play_one(alice, id)
    expect(status).to eq(200)
    expect(runner.wait_idle(id, timeout: 60)).to be(true)
    _, now = alice.api(:get, "/games/#{id}")
    expect(now["state"]["prompt"]["viewer_to_act"]).to be(true)
    expect(now["seq"]).to be >= 3
    expect(alice.api(:get, "/games/#{id}/version")[1]["seq"]).to eq(now["seq"])
  end

  it "leaves bot seats alone when the runner is off" do
    Sinatra::Application.set :bot_mode, :off
    _, game = alice.api(:post, "/games", { seats: [{ kind: "human", account_id: "alice" }, { kind: "bot" }], seed: 2 })
    expect(game["seq"]).to eq(0)
  end
end

# The authorizer decides who may act for which entity. The HTTP specs above stay in
# the auction (players as entities); this checks a corporation in an operating round,
# on a real state reached by playing a strategy game directly.
RSpec.describe "games API authorizer (#36)" do
  require "oe/strategy_player"

  let(:host) do
    Class.new do
      include Oe::GamesApi::Helpers
    end.new
  end

  it "lets only the president act for an operating corporation" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    until Oe::View.round_type(game.round) == "operating"
      actions = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      game.process_action(strategist.choose(actions) || actions.sample(random: rng))
    end

    corporation = game.round.active_entities.first
    expect(corporation.player?).to be(false)
    president = corporation.player.id
    other = (%w[p0 p1 p2 p3] - [president]).first
    action = { "type" => "pass", "entity" => corporation.id, "entity_type" => "corporation" }

    expect { host.authorizer(president, action).call(game) }.not_to raise_error
    expect { host.authorizer(other, action).call(game) }
      .to raise_error(Oe::GameSession::Forbidden) { |e| expect(e.code).to eq("not_your_turn") }
    expect { host.authorizer(nil, action).call(game) }
      .to raise_error(Oe::GameSession::Forbidden) { |e| expect(e.code).to eq("forbidden") }
    expect { host.authorizer(president, action.merge("entity" => "ZZ")).call(game) }
      .to raise_error(Oe::GameSession::Forbidden)
  end
end
