# frozen_string_literal: true

module Oe
  class Bot
    # Stock round (buy, par, sell).
    #
    # - sell only when it is the only way to continue (forced) — the smallest bundle,
    # - first top up companies the bot already presides over,
    # - otherwise buy where the last dividend yields the most per share price,
    # - par a new company only if it can afford its start (Oe::StrategyPlayer's
    #   par rule: 2 x par covers track rights plus a first train),
    # - and pass fairly often: shares are bought when they look good, not always.
    class Stock
      PASS_ONE_IN = 4

      def initialize(game, rng, fallback)
        @game = game
        @rng = rng
        @fallback = fallback
      end

      def choose(by_class)
        buys = by_class["BuyShares"]
        pars = by_class["Par"]
        sells = by_class["SellShares"]
        pass = by_class["Pass"]&.first

        # Forced: only selling (e.g. a president buying a train) — raise the least money needed.
        return sells.min_by { |a| a.bundle.percent } if sells && !pass && !buys && !pars
        return @fallback.send(:pick_par, pars, by_class) || pass if pars && !buys
        return pass || sells&.min_by { |a| a.bundle.percent } unless buys || pars

        player = (buys || pars).first.entity
        return pass if pass && @rng.rand(PASS_ONE_IN).zero?

        candidates = buys.to_a.map { |a| [score(player, a), a] }
        par = pars && @fallback.send(:pick_par, pars, by_class)
        candidates << [PAR_SCORE, par] if par
        Pick.weighted(candidates, @rng) || pass
      end

      PAR_SCORE = 12.0

      private

      def score(player, buy)
        corporation = buy.bundle.corporation
        own = corporation.president?(player) ? 40.0 : 0.0
        own + yield_percent(corporation)
      end

      # Last run revenue per share price, in percent; unknown (never ran) counts as modest.
      def yield_percent(corporation)
        price = corporation.share_price&.price.to_i
        return 0.0 if price.zero?

        revenue = corporation.operating_history.to_a.last&.last&.revenue
        revenue ? (revenue.to_f / price) * 100 : 5.0
      end
    end
  end
end
