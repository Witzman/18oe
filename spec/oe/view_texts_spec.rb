# frozen_string_literal: true

require "spec_helper"
require "oe/view"
require "oe/catalog"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"
require_relative "../engine/g_18_oe/helpers"
require_relative "../support/view_checks"

# #124: the step's texts, the labels of the choices, the card catalog and who
# holds which card.
RSpec.describe "Oe::View texts and catalog (#124)" do
  G = Engine::Game::G18OE unless defined?(G)

  describe "catalog" do
    let(:catalog) { Oe::Catalog.build }

    it "holds 10 privates, 12 minors, 10 concessions and 24 regionals" do
      expect(catalog.transform_values(&:size)).to eq(privates: 10, minors: 12, concessions: 10, regionals: 24)
    end

    it "has name, text, value and income of every card, and ids that are unique per kind" do
      (catalog[:privates] + catalog[:concessions] + catalog[:minors].map { |m| m[:charter] }).each do |c|
        expect(c[:name].to_s).not_to be_empty
        expect(c[:text].to_s).not_to be_empty
        expect(c[:value]).to be_a(Integer)
        expect(c[:revenue]).to be_a(Integer)
      end
      catalog.each_value { |list| expect(list.map { |c| c[:id] }.uniq.size).to eq(list.size) }
    end

    it "has colour and token prices of every minor and regional, a home hex and zone for every regional" do
      (catalog[:minors] + catalog[:regionals]).each do |c|
        expect(c[:color]).to match(/\A#\h{6}\z/)
        expect(c[:token_prices]).to all(be_a(Integer))
        expect(c[:name].to_s).not_to be_empty
      end
      catalog[:regionals].each do |r|
        expect(r[:home]).to match(/\A[A-Z]+\d+\z/)
        expect(G::Game::CORPORATIONS_TRACK_RIGHTS[r[:id]]).to eq(r[:zone])
        expect(G::Game.new(%w[p0 p1 p2], id: 1, seed: 1).hex_by_id(r[:home])).not_to be_nil
      end
    end

    it "matches the engine's entity tables and survives a JSON round trip" do
      expect(JSON.parse(Oe::Catalog.json).keys).to eq(%w[schema privates minors concessions regionals])
      game = G::Game.new(%w[p0 p1 p2], id: 1, seed: 1)
      expect(catalog[:minors].map { |m| m[:name] }).to eq(game.corporations.select { |c| c.type == :minor }.map(&:full_name))
      expect(catalog[:concessions].map { |c| c[:id] }).to eq(game.concessions.map(&:id).sort_by { |id| id[/\d+/].to_i })
    end
  end

  describe "GET /catalog" do
    include Rack::Test::Methods

    def app = Sinatra::Application

    before do
      Sinatra::Application.set :store, Oe::Store.new(":memory:")
      seed_accounts(Sinatra::Application.settings.store, %w[alice])
    end

    it "is behind the login and then serves the catalog with an ETag" do
      get "/catalog", {}, { "HTTP_HOST" => "127.0.0.1" }
      expect(last_response.status).to eq(401)
      post "/login", JSON.generate(login: "alice", password: TEST_PASSWORD), { "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1" }
      get "/catalog", {}, { "HTTP_HOST" => "127.0.0.1" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["regionals"].size).to eq(24)
      tag = last_response.headers["ETag"]
      expect(tag).not_to be_nil
      get "/catalog", {}, { "HTTP_HOST" => "127.0.0.1", "HTTP_IF_NONE_MATCH" => tag }
      expect(last_response.status).to eq(304)
    end
  end

  describe "prompt texts", :game_flow do
    include OeViewChecks

    # A game that takes `choose` whenever it can, so the rarer dialogs come up.
    before(:all) do
      @steps = Hash.new(0)
      @errors = []
      @chooses = 0
      @labels = {}
      [2, 3].each do |seed|
        game = G::Game.new(%w[p0 p1 p2 p3], id: seed, seed: seed)
        rng = Random.new(seed)
        strategist = Oe::StrategyPlayer.new(game, rng: rng)
        count = 0
        until game.finished || count > 2500
          view = Oe::View.render(game, viewer: game.active_players.first&.id, log: nil)
          check(game, view)
          acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
          break if acts.empty?

          picks = acts.grep(Engine::Action::Choose)
          game.process_action((picks.sample(random: rng) if rng.rand < 0.6) || strategist.choose(acts) || acts.sample(random: rng))
          count += 1
        end
      end
    end

    # The checks are OeViewChecks#prompt_text_errors (spec/support/view_checks.rb); this counts what they saw.
    def check(game, view)
      prompt = view[:prompt]
      name = prompt[:step]
      @steps[name] += 1
      @errors.concat(prompt_text_errors(game, view))
      prompt[:choices].each do |c|
        @chooses += 1
        @labels[[name, c[:choice]]] = c[:label]
      end
    end

    it "gives description, pass label and help from the step in every state" do
      expect(@steps.size).to be >= 5
      expect(@errors.first(5)).to eq([])
    end

    it "labels every offered choice with the engine's own text" do
      expect(@chooses).to be > 0
      expect(@labels.values).to include("Remove from game", "Reserve share")
    end

    it "labels choices without a target and the question of the reserve dialog (unit)" do
      game = G::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
      step = Struct.new(:choices, :choice_name).new({ "a" => "Alpha" }, "Which?")
      act = Engine::Action::Choose.new(game.players.first, choice: "a")
      expect(Oe::View.choice_label(game, step, act)).to eq("Alpha")
      other = Engine::Action::Choose.new(game.players.first, choice: "zz")
      expect(Oe::View.choice_label(game, step, other)).to eq("zz")
    end
  end

  # #438: the same checks over states built by code (fast stage), one per kind of step a seed game passes.
  describe "prompt texts in states built by code (#438)" do
    include G18OESpecHelpers
    include OeViewChecks

    let(:game) { new_game(%w[p0 p1 p2 p3]) }

    def prompt_of(game)
      view = Oe::View.render(game, viewer: game.active_players.first.id, log: nil)
      expect(prompt_text_errors(game, view)).to eq([])
      view[:prompt]
    end

    it "holds in the opening auction" do
      expect(prompt_of(game)[:actions]).not_to be_empty
    end

    it "holds in the initial stock round, with the reserve dialog's labels" do
      start_regional!(game, "LNWR", game.players[0])
      stock_round!(game, turn: 1)

      expect(prompt_of(game)[:choices].map { |c| c[:label] }).to include("Reserve share", "Remove from game")
    end

    it "holds in a later stock round" do
      start_regional!(game, "LNWR", game.players[0])
      start_regional!(game, "GWR", game.players[1])
      stock_round!(game)

      expect(prompt_of(game)[:actions]).not_to be_empty
    end

    it "holds through a regional's operating turn" do
      corp = operating_regional!(game, "LNWR", game.players[0])
      operating_round_for!(game, 1, setup: true)
      steps = []
      10.times do
        break unless game.round.operating? && game.round.active_step&.current_entity == corp

        steps << prompt_of(game)[:step]
        case game.round.active_step
        when Engine::Step::Route
          act!(game, Engine::Action::RunRoutes.new(corp, routes: Oe::LegalActions::RoutePicker.new(game, corp).call))
        when Engine::Step::Dividend then act!(game, Engine::Action::Dividend.new(corp, kind: "payout"))
        else act!(game, Engine::Action::Pass.new(corp))
        end
      end

      expect(steps).to include("Track", "BuyTrain")
    end

    # #425: Hochberg's token (§14.8) is the choice of a non-blocking step during Track; its label was looked up
    # only in the active step, so the view showed the choice's id.
    it "labels the choice of a non-blocking step: Hochberg's token during Track (#425)" do
      give_company!(game.players[0], game.company_by_id("HMLC"))
      start_major!(game, "LNWR", game.players[0])
      operating_round_for!(game, 1, setup: true)

      prompt = prompt_of(game)

      expect(prompt[:step]).to eq("Track")
      expect(prompt[:choices].map { |c| c[:label] }.uniq).to eq(["Place token"])
    end
  end

  describe "companies" do
    it "lists all 32 cards with owner, closed, face-down and abilities, hiding a foreign face-down card's abilities" do
      game = G::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
      rng = Random.new(1)
      strategist = Oe::StrategyPlayer.new(game, rng: rng)
      300.times do
        break if game.finished || !game.round.is_a?(Engine::Round::Auction) && game.turn > 1

        acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
        game.process_action(strategist.choose(acts) || acts.sample(random: rng))
      end
      view = Oe::View.render(game, viewer: "p0", log: nil, actions: false)
      list = view[:companies]
      expect(list.size).to eq(32)
      expect(list.map { |c| c[:kind] }.tally).to eq("private" => 10, "minor" => 12, "concession" => 10)
      view[:players].each do |pl|
        mine = list.select { |c| c[:owner] == { kind: "player", id: pl[:id] } }.map { |c| c[:id] }
        expect(mine.sort).to eq(pl[:companies].map { |c| c[:id] }.sort)
      end
      expect(list.count { |c| c[:owner] }).to be > 0
      expect(JSON.parse(JSON.generate(list)).first.keys).to eq(%w[id kind owner closed face_down abilities])
    end

    it "shows used and remaining of a live ability, and nothing of a foreign face-down card" do
      game = G::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
      company = game.companies.find { |c| c.all_abilities.any? }
      company.owner = game.players[1]
      game.players[1].companies << company
      mine = Oe::View.companies(game, "p1").find { |c| c[:id] == company.id }
      ability = company.all_abilities.first
      expect(mine[:abilities].first).to eq(type: ability.type.to_s, used: false, remaining: ability.count)
      game.instance_variable_get(:@face_down_privates) << company
      expect(Oe::View.companies(game, "p0").find { |c| c[:id] == company.id }[:abilities]).to eq([])
      expect(Oe::View.companies(game, "p1").find { |c| c[:id] == company.id }[:abilities]).not_to be_empty
    end
  end
end
