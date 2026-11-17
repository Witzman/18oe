# frozen_string_literal: true

require_relative "legal_actions"
require_relative "strategy_player"
require_relative "bot/pick"
require_relative "bot/auction"
require_relative "bot/stock"
require_relative "bot/track"
require_relative "bot/token"
require_relative "bot/dividend"
require_relative "bot/green_junction"

module Oe
  # Bot v1 (#37): rule-based heuristics with seeded randomness. Local only —
  # no LLM, no network, no cost per move (rule 7 of the workshop).
  #
  #   bot = Oe::Bot.new(game, rng: Random.new(seed))
  #   action = bot.choose(player_id: "p2")   # an Engine::Action, ready to submit
  #
  # `choose` looks at the legal actions (Oe::LegalActions) the given player may
  # play right now — for the player itself or for a corporation it presides
  # over — and picks one. It can only return legal actions.
  #
  # Heuristics per action family, one small class each (Bot::Auction with
  # Bot::Valuation for what privates and minors are worth (#313),
  # Bot::Stock, Bot::Track, Bot::Token, Bot::Dividend, Bot::GreenJunction). Everything else — train purchases,
  # routes, merges, discards — falls back to the rules of
  # Oe::StrategyPlayer (#32), which already carries whole games to the end.
  #
  # Dividends no longer use StrategyPlayer's "withhold in the first run"
  # memory (#327), so a restarted Bot decides them the same way.
  class Bot
    # A stand-in for Random whose seed can be replaced: the bot components keep
    # one rng object, the bot runner reseeds it per move (game seed + seq), so a
    # replay can explain the same choices. Responds to what Array#sample needs.
    class Rng
      def initialize(random)
        @random = random
      end

      def reseed(seed)
        @random = Random.new(seed)
      end

      def rand(*args)
        @random.rand(*args)
      end
    end

    # Families handled here. Anything not listed goes to the fallback.
    SPECIAL = %w[Bid Par BuyShares SellShares Assign LayTile PlaceToken Dividend].freeze
    # If one of these is on offer, the fallback decides (same order of
    # precedence as StrategyPlayer: train purchase comes first). Dividend: Bot::Dividend (#327).
    FALLBACK_FIRST = %w[BuyTrain RunRoutes].freeze

    attr_reader :game

    def self.choose(game, rng:, player_id: nil, limit: 12, profile: :standard, valuation: :derived)
      new(game, rng: rng, limit: limit, profile: profile, valuation: valuation).choose(player_id: player_id)
    end

    # profile: :einfach | :standard (= :mittel) | :schwer (Bot::Valuation::PROFILES, #313)
    # valuation: :derived (Bot::Valuation) | :face (face-value auction before #313)
    def initialize(game, rng: Random.new(0), limit: 12, profile: :standard, valuation: :derived)
      @game = game
      @rng = Rng.new(rng)
      @limit = limit
      @fallback = StrategyPlayer.new(game, rng: @rng)
      @auction = Auction.new(game, @rng, valuation: valuation, profile: profile)
      @stock = Stock.new(game, @rng, @fallback)
      @track = Track.new(game, @rng)
      @token = Token.new(game, @rng, @track)
      @dividend = Dividend.new(game, @rng)
      @green_junction = GreenJunction.new(game, @rng)
    end

    # Replace the random stream (see Rng); the same seed gives the same choice for the same state.
    def reseed(seed)
      @rng.reseed(seed)
    end

    # Returns nil when the player has nothing to do right now.
    def choose(player_id: nil)
      actions = legal_actions(player_id)
      return if actions.empty?

      by_class = actions.group_by { |a| a.class.name.split("::").last }
      return @fallback.choose(actions) if (by_class.keys & FALLBACK_FIRST).any?

      special(by_class) || @fallback.choose(actions)
    end

    # The legal actions of the game, restricted to those `player_id` may issue.
    def legal_actions(player_id)
      actions = Oe::LegalActions.new(@game, limit: @limit, rng: @rng).call
      return actions unless player_id

      # Bots do not use privates yet: an action a private issues itself (#128)
      # stays unplayed until the bot learns that private (S8, #77 ff.).
      actions.select { |a| !a.entity.company? && acting_player(a.entity)&.id == player_id }
    end

    private

    def acting_player(entity)
      entity.player? ? entity : entity.player
    end

    def special(by_class)
      return @dividend.choose(by_class) if by_class["Dividend"]
      return @auction.choose(by_class) if by_class["Bid"]
      return @stock.choose(by_class) if by_class.key?("Par") || by_class.key?("BuyShares") || by_class.key?("SellShares")
      return @green_junction.choose(by_class["Assign"]) if by_class["Assign"]
      return @track.choose(by_class) if by_class["LayTile"]
      return @token.choose(by_class) if by_class["PlaceToken"]

      nil
    end
  end
end
