# frozen_string_literal: true

require_relative "legal_actions"
require_relative "strategy_player"
require_relative "bot/pick"
require_relative "bot/auction"
require_relative "bot/stock"
require_relative "bot/track"
require_relative "bot/token"

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
  # Heuristics per action family, one small class each (Bot::Auction,
  # Bot::Stock, Bot::Track, Bot::Token). Everything else — dividends, train purchases,
  # routes, merges, discards — falls back to the rules of
  # Oe::StrategyPlayer (#32), which already carries whole games to the end.
  #
  # Keep one Bot per game: StrategyPlayer remembers how often a corporation has
  # operated (withhold in the first run). After a restart that memory is empty,
  # which only costs the "withhold first" habit once.
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
    SPECIAL = %w[Bid Par BuyShares SellShares LayTile PlaceToken].freeze
    # If one of these is on offer, the fallback decides (same order of
    # precedence as StrategyPlayer: train purchase and dividend come first).
    FALLBACK_FIRST = %w[BuyTrain Dividend RunRoutes].freeze

    attr_reader :game

    def self.choose(game, rng:, player_id: nil, limit: 12)
      new(game, rng: rng, limit: limit).choose(player_id: player_id)
    end

    def initialize(game, rng: Random.new(0), limit: 12)
      @game = game
      @rng = Rng.new(rng)
      @limit = limit
      @fallback = StrategyPlayer.new(game, rng: @rng)
      @auction = Auction.new(game, @rng)
      @stock = Stock.new(game, @rng, @fallback)
      @track = Track.new(game, @rng)
      @token = Token.new(game, @rng, @track)
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

      actions.select { |a| acting_player(a.entity)&.id == player_id }
    end

    private

    def acting_player(entity)
      entity.player? ? entity : entity.player
    end

    def special(by_class)
      return @auction.choose(by_class) if by_class["Bid"]
      return @stock.choose(by_class) if by_class.key?("Par") || by_class.key?("BuyShares") || by_class.key?("SellShares")
      return @track.choose(by_class) if by_class["LayTile"]
      return @token.choose(by_class) if by_class["PlaceToken"]

      nil
    end
  end
end
