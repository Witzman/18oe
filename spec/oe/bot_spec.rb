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

  describe Oe::Bot::Auction do
    let(:cheap) { Co.new(60) }
    let(:minor) { Co.new(100) }
    let(:game) { Game.new([minor]) }
    let(:rng) { Random.new(3) }
    let(:auction) { described_class.new(game, rng) }

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
      picks = Array.new(200) { |i| described_class.new(game, Random.new(i)).choose({ "Bid" => bids, "Pass" => [Pass.new(player)] }) }
      expect(picks.count { |a| a.is_a?(Bid) }).to be > 150
      expect(picks.count { |a| a.is_a?(Pass) }).to be > 0
    end

    it "prefers the company that becomes a minor" do
      player = Player.new(1000, "p0")
      bids = [Bid.new(player, cheap, 60), Bid.new(player, minor, 100)]
      picks = Array.new(300) { |i| described_class.new(game, Random.new(i)).choose({ "Bid" => bids }) }
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
    Corp = Struct.new(:trains, :cash)

    it "passes instead of spending the treasury on track before the first train" do
      corp = Corp.new([], 100)
      expect(track.choose({ "LayTile" => [LayTile.new(corp)], "Pass" => [Pass.new(corp)] })).to be_a(Pass)
    end

    it "must lay a tile when passing is not allowed" do
      corp = Corp.new([], 100)
      tile = LayTile.new(corp)
      expect(track.choose({ "LayTile" => [tile] })).to equal(tile)
    end
  end

  describe "on a real game" do
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

    it "plays a whole 4-player game to a regular end without an illegal action" do
      game = new_game(1)
      bot = described_class.new(game, rng: Random.new(1))
      count = 0
      until game.finished || count > 20_000
        action = bot.choose
        expect(action).not_to be_nil, "dead end after #{count} actions"
        game.process_action(action)
        expect(game.exception).to be_nil, "rejected after #{count} actions: #{game.exception&.message}"
        count += 1
      end
      expect(game.finished).to be(true)
      expect(game.result.values.max).to be > 0
    end
  end
end
