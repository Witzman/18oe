# frozen_string_literal: true

require_relative "valuation"

module Oe
  class Bot
    # Waterfall auction (privates, minor charters, concessions).
    #
    # Two variants, chosen per bot (`valuation:`):
    #
    # :derived (default, #313) - Bot::Valuation says what each item is worth
    #   (face value + ability x map fit + synergy with what the bot owns, quota
    #   10/N privates and 12/N minors, profile). The bot bids the lowest legal
    #   amount on items worth at least that, never below its reserve for the
    #   regional floats, and picks among them by surplus (value - price).
    #
    # :face (before #313, kept for comparison in bin/bot-audit) -
    #   - never bids so much that the cash left drops below RESERVE,
    #   - a company that turns into a minor is worth more than a plain private,
    #   - prefers bargains (value above price) and low prices,
    #   - bids at most PREMIUM above the company's value.
    #
    # Both pass when nothing fits - unless pass is not allowed, then the cheapest bid.
    class Auction
      RESERVE = 100
      PREMIUM = 20

      attr_reader :valuation

      def initialize(game, rng, valuation: :derived, profile: :standard)
        @game = game
        @rng = rng
        @mode = valuation.to_sym
        @profile = Valuation.profile(profile)
        @valuation = Valuation.new(game, rng) if @mode == :derived
      end

      def choose(by_class)
        @mode == :derived ? choose_derived(by_class) : choose_face(by_class)
      end

      # ---- derived (#313) ---------------------------------------------------

      def choose_derived(by_class)
        bids = by_class["Bid"]
        pass = by_class["Pass"]&.first
        player = bids.first.entity
        step = @game.round.active_step
        stellung = Valuation::Stellung.from(@game, player, step)

        candidates = lowest_bids(bids, step, player).filter_map do |bid|
          worth = @valuation.value(bid.company, stellung, @profile)
          next if bid.price > worth || !@valuation.affordable?(bid.price, stellung)

          [worth - bid.price, bid]
        end
        return Pick.weighted(candidates, @rng) unless candidates.empty?

        pass || bids.min_by { |bid| [bid.price, bid.company.value] }
      end

      # One bid per company, the lowest legal amount; none where the bot already
      # holds the highest bid (it would only outbid itself). At most one open bid
      # on a lower row at a time: each one ties up cash (committed), and with the
      # regional reserve the bot could no longer buy from the top row, so the
      # whole table would pass and the packet would drop to giveaway prices.
      def lowest_bids(bids, step, player)
        lower_bid_open = open_lower_bid?(step, player)
        bids.group_by(&:company).filter_map do |company, list|
          high = step.respond_to?(:highest_bid, true) ? step.send(:highest_bid, company) : nil
          next if high && high.entity == player
          next if lower_bid_open && !top_row?(step, company)

          list.min_by(&:price)
        end
      end

      # Lower-row bids tie up cash until the row above sells out; a bid in the
      # top row (purchase or open auction) settles at once.
      def top_row?(step, company)
        return true unless step.respond_to?(:top_row?, true)

        step.send(:top_row?, company)
      end

      def open_lower_bid?(step, player)
        return false unless step.respond_to?(:bids_for_player, true) # protected in Engine::Step::Auctioner

        step.send(:bids_for_player, player).any? { |bid| !top_row?(step, bid.company) }
      end

      # ---- face value (before #313) -----------------------------------------

      def choose_face(by_class)
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
