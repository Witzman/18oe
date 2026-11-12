# frozen_string_literal: true

module Oe
  class Bot
    # Waterfall auction (private companies / concessions).
    #
    # - never bids so much that the cash left drops below RESERVE (the player
    #   needs money to float a company afterwards),
    # - a company that turns into a minor is worth more than a plain private,
    # - prefers bargains (value above price) and low prices,
    # - bids at most PREMIUM above the company's value,
    # - passes when nothing fits — unless pass is not allowed, then the cheapest bid.
    class Auction
      RESERVE = 100
      PREMIUM = 20

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def choose(by_class)
        bids = by_class["Bid"]
        pass = by_class["Pass"]&.first
        player = bids.first.entity
        fitting = bids.select { |bid| fits?(player, bid) }

        if fitting.empty?
          return pass if pass

          return bids.min_by { |bid| [bid.price, bid.company.value] }
        end

        # Occasionally pass although something fits: the bot is not a vacuum cleaner.
        return pass if pass && @rng.rand(10).zero?

        Pick.weighted(fitting.map { |bid| [score(bid), bid] }, @rng)
      end

      def fits?(player, bid)
        bid.price <= bid.company.value + PREMIUM && player.cash - bid.price >= RESERVE
      end

      def score(bid)
        company = bid.company
        bonus = @game.company_becomes_minor?(company) ? 30 : 0
        bonus + ((company.value - bid.price) / 5.0) - (bid.price / 25.0)
      end
    end
  end
end
