# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot"

RSpec.describe Oe::Bot do
  Co = Struct.new(:value)
  Player = Struct.new(:cash, :id) do
    def player? = true
  end
  Bid = Struct.new(:entity, :company, :price)
  Pass = Struct.new(:entity)
  Game = Struct.new(:minor_ids) do
    def company_becomes_minor?(company) = minor_ids.include?(company)
  end

  describe Oe::Bot::Pick do
    it "returns nil for no candidates" do
      expect(described_class.weighted([], Random.new(1))).to be_nil
    end

    it "only picks among the three best and favours the best" do
      scored = [[1, :c], [9, :a], [5, :b], [0, :d], [4, :e]]
      picks = Array.new(2000) { |i| described_class.weighted(scored, Random.new(i)) }
      expect(picks.uniq.sort).to eq(%i[a b e])
      expect(picks.count(:a)).to be > picks.count(:b)
      expect(picks.count(:b)).to be > picks.count(:e)
    end

    it "is deterministic for a seed and stable for equal scores" do
      scored = [[3, :x], [3, :y], [3, :z]]
      expect(Array.new(20) { described_class.weighted(scored, Random.new(7)) }.uniq.size).to eq(1)
    end
  end

  describe "Oe::Bot::Auction (face value, before #313)" do
    let(:cheap) { Co.new(60) }
    let(:minor) { Co.new(100) }
    let(:game) { Game.new([minor]) }
    let(:rng) { Random.new(3) }
    let(:auction) { Oe::Bot::Auction.new(game, rng, valuation: :face) }

    it "does not bid above value plus the premium" do
      player = Player.new(1000, "p0")
      bids = [Bid.new(player, cheap, 200), Bid.new(player, cheap, 90)]
      expect(auction.choose({ "Bid" => bids, "Pass" => [Pass.new(player)] })).to be_a(Pass)
    end

    it "keeps a cash reserve for floating a company" do
      player = Player.new(150, "p0")
      bids = [Bid.new(player, cheap, 60)] # leaves 90 < reserve 100
      expect(auction.choose({ "Bid" => bids, "Pass" => [Pass.new(player)] })).to be_a(Pass)
    end

    it "bids on an affordable company (sometimes passing is allowed)" do
      player = Player.new(1000, "p0")
      bids = [Bid.new(player, cheap, 60), Bid.new(player, cheap, 70)]
      picks = Array.new(200) { |i| Oe::Bot::Auction.new(game, Random.new(i), valuation: :face).choose({ "Bid" => bids, "Pass" => [Pass.new(player)] }) }
      expect(picks.count { |a| a.is_a?(Bid) }).to be > 150
      expect(picks.count { |a| a.is_a?(Pass) }).to be > 0
    end

    it "prefers the company that becomes a minor" do
      player = Player.new(1000, "p0")
      bids = [Bid.new(player, cheap, 60), Bid.new(player, minor, 100)]
      picks = Array.new(300) { |i| Oe::Bot::Auction.new(game, Random.new(i), valuation: :face).choose({ "Bid" => bids }) }
      expect(picks.count { |a| a.company == minor }).to be > picks.count { |a| a.company == cheap }
    end

    it "takes the cheapest bid when nothing fits and passing is not allowed" do
      player = Player.new(50, "p0")
      bids = [Bid.new(player, cheap, 60), Bid.new(player, cheap, 70)]
      expect(auction.choose({ "Bid" => bids }).price).to eq(60)
    end
  end

  describe Oe::Bot::Track do
    let(:track) { described_class.new(Struct.new(:x).new(0), Random.new(1)) }
    LayTile = Struct.new(:entity, :tile, :hex)
    Corp = Struct.new(:trains, :cash, :owner)
    Depot = Struct.new(:min_depot_price)

    it "keeps the cheapest train back while trainless, less half the president's cash (#293)" do
      game = Struct.new(:depot).new(Depot.new(100))
      track = described_class.new(game, Random.new(1))
      president = Player.new(60, "p0")
      expect(track.reserve(Corp.new([], 100, president))).to eq(70)
      expect(track.reserve(Corp.new([], 100, Player.new(400, "p0")))).to eq(0)
      expect(track.reserve(Corp.new([:train], 100, president))).to eq(0)
    end
  end

  # Operating round 1.1 / 1.2 of a real 4-bot game (#293): before #293 every
  # company passed its track points and its token in OR 1.1.
  describe "operating", :game_flow do
    def play_until(seed)
      game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: seed, seed: seed)
      bot = described_class.new(game, rng: Random.new(seed))
      log = []
      @stops_after = {} # entity => connected stops right after its own latest action (not at the end of the OR)
      20_000.times do
        break if yield(game)

        action = bot.choose
        step = game.round.active_step
        log << [game.round.operating? ? "#{game.turn}.#{game.round.round_num}" : nil, step.class.name.split("::").last, action]
        game.process_action(action)
        raise game.exception if game.exception

        entity = action.entity
        next unless entity.corporation?
        # only what it could run when its Route step came: Transfer Tokens, Buy Trains and Issue Shares act later
        next unless %w[Track Token SpecialToken Assign HomeToken].include?(log.last[1])

        # the engine's own question (Game#can_run_route?, Graph#route_info), as its Route step asks it (#563)
        @stops_after[entity] = game.can_run_route?(entity) ? 2 : 0 # Chris' route_info: two stops (also over the sea) and a train
      end
      [game, log]
    end

    def in_or(log, round, step)
      log.select { |r, s, _| r == round && s == step }.map(&:last)
    end

    let(:until_or12_done) { ->(g) { g.round.operating? && g.turn == 2 } }

    it "lays track in OR 1.1 with most companies" do
      _, log = play_until(1, &until_or12_done)
      lays = in_or(log, "1.1", "Track")
      laying = lays.grep(Engine::Action::LayTile).map(&:entity).uniq
      everyone = lays.map(&:entity).uniq
      expect(laying.size).to be >= everyone.size * 3 / 4
    end

    it "places tokens in OR 1.1 when affordable" do
      tokens = in_or(play_until(1, &until_or12_done).last, "1.1", "Token")
      expect(tokens.grep(Engine::Action::PlaceToken)).not_to be_empty
    end

    it "runs a route with revenue for every company with a train that has one to run in OR 1.2" do
      game, log = play_until(1, &until_or12_done)
      runs = in_or(log, "1.2", "Route").select { |a| a.is_a?(Engine::Action::RunRoutes) }
      # an insolvent minor or regional (RB 11.6.5) sits in the Open Market and does not operate
      with_train = game.corporations.select { |c| c.floated? && !c.trains.empty? && !game.insolvent?(c) }
      expect(runs.map { |a| a.routes.sum(&:revenue) }).to all(be_positive)
      # A company with a train but fewer than two connected stops has no route to run. Measured for seed 1
      # (#314): the five without a run are all that case (no cash or no legal lay left: no upgradeable
      # tile, or only lays the engine's TRACK_RESTRICTION rejects, #309), not a bot or enumerator miss.
      ran = runs.map { |a| a.entity }
      idle = with_train - ran
      # Judged by the stops it had at its own turn: tiles other companies lay later in the OR can connect it
      # afterwards (#321: the new Track score changes who lays what, so the end state is not the right moment).
      expect(idle).to all(satisfy { |c| @stops_after.fetch(c) < 2 })
      expect(runs.size).to be >= with_train.size / 2
    end

    it "lays a tile on the company's network that reaches out (new stop or closer to one)" do
      # The first Track step may legitimately pass (no lay brings progress, e.g. after the auction of #313
      # changed who owns what), so look at the first Track step where the bot does lay.
      game, = play_until(2) { |g| g.round.operating? && g.round.active_step.is_a?(Engine::Step::Track) }
      bot = described_class.new(game, rng: Random.new(2))
      action = nil
      2_000.times do
        action = bot.choose
        break if action.is_a?(Engine::Action::LayTile)

        game.process_action(action)
        raise game.exception if game.exception
      end
      expect(action).to be_a(Engine::Action::LayTile)
      entity = action.entity
      graph = game.graph_for_entity(entity)
      before = [graph.connected_nodes(entity).size, graph.connected_hexes(entity).size]
      game.process_action(action)
      expect(game.exception).to be_nil
      game.clear_graph
      graph = game.graph_for_entity(entity)
      after = [graph.connected_nodes(entity).size, graph.connected_hexes(entity).size]
      expect(after[0] > before[0] || after[1] > before[1]).to be(true), "network did not grow: #{before} -> #{after}"
    end
  end

  describe Oe::Bot::Token do
    TokCity = Struct.new(:tokens, :max_revenue, :hex)
    TokHex = Struct.new(:id)
    TokGame = Struct.new(:metro) do
      def metropolis_hex?(hex) = hex.id == metro
      def self.const_missing(_) = super
    end
    let(:game) do
      klass = Class.new(TokGame) { const_set(:PORTS, { "PORT" => { 1 => { port: :public } } }) }
      klass.new("METRO")
    end
    let(:token) { described_class.new(game, Random.new(1), nil) }

    def city(slots, free, revenue, hex = "X")
      TokCity.new(Array.new(slots) { |i| i < free ? nil : :t }, revenue, TokHex.new(hex))
    end

    it "scores the last free slot above a city with room left" do
      expect(token.send(:score, city(3, 1, 20))).to be > token.send(:score, city(3, 2, 20))
    end

    it "scores a small city (bottleneck) above a big one with equal room" do
      expect(token.send(:score, city(2, 2, 20))).to be > token.send(:score, city(4, 2, 20))
    end

    it "scores target cities (metropolis, port) above a plain city of equal revenue" do
      plain = token.send(:score, city(3, 2, 20))
      expect(token.send(:score, city(3, 2, 20, "METRO"))).to be > plain
      expect(token.send(:score, city(3, 2, 20, "PORT"))).to be > plain
    end

    it "picks the top-scored city most often" do
      corp = Struct.new(:cash, :trains) do
        def corporation? = true
      end.new(500, [1])
      Act = Struct.new(:entity, :city) unless defined?(Act)
      best = Act.new(corp, city(3, 1, 20, "METRO"))
      worse = Act.new(corp, city(4, 3, 10))
      allow_any_instance_of(described_class).to receive(:price).and_return(0)
      picks = Array.new(200) { |i| described_class.new(game, Random.new(i), double("track", reserve: 0)).choose({ "PlaceToken" => [worse, best], "Pass" => [Pass.new(corp)] }) }
      expect(picks.count(best)).to be > picks.count(worse)
    end
  end

  describe "on a real game", :game_flow do
    let(:names) { %w[p0 p1 p2 p3] }

    def new_game(seed)
      Engine::Game::G18OE::Game.new(names, id: seed, seed: seed)
    end

    it "returns a legal action only for the player who is to act" do
      game = new_game(1)
      bot = described_class.new(game, rng: Random.new(1))
      acting = game.active_players.first.id
      other = (names - [acting]).first

      expect(bot.choose(player_id: other)).to be_nil
      action = bot.choose(player_id: acting)
      expect(action).not_to be_nil
      game.process_action(action)
      expect(game.exception).to be_nil
    end

    it "plays a reproducible game for a seed (same actions twice)" do
      runs = Array.new(2) do
        game = new_game(2)
        bot = described_class.new(game, rng: Random.new(2))
        300.times do
          action = bot.choose
          break unless action

          game.process_action(action)
          raise game.exception if game.exception
        end
        game.raw_actions.map { |a| a.reject { |k, _| k == "created_at" } }
      end
      expect(runs.first).to eq(runs.last)
      expect(runs.first.size).to eq(300)
    end

    it "plays #{GAME_CAP} actions of a 4-player game without an illegal action or dead end" do
      game = new_game(1)
      bot = described_class.new(game, rng: Random.new(1))
      count = 0
      until game.finished || count >= GAME_CAP
        action = bot.choose
        expect(action).not_to be_nil, "dead end after #{count} actions"
        game.process_action(action)
        expect(game.exception).to be_nil, "rejected after #{count} actions: #{game.exception&.message}"
        count += 1
      end
      expect(game.raw_actions.size).to be >= [GAME_CAP, 1000].min
      expect(game.result.values.max).to be > 0
    end
  end
end
