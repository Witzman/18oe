# frozen_string_literal: true

module Oe
  class Bot
    # Station tokens (#293): place one whenever it is affordable. The offered
    # cities are already the legal ones (connected to the company's network,
    # inside its track rights; LegalActions#token_targets). A company without
    # a train keeps the cheapest depot train's price back, like Bot::Track.
    #
    # Choice: the city with the highest revenue, then the one with the fewest
    # free slots left (claim it before a rival does); seeded among the best
    # three. Before #293 the fallback passed while the company had no train or
    # less than 140 cash, so bots never placed a token in OR 1.1.
    class Token
      def initialize(game, rng, track)
        @game = game
        @rng = rng
        @track = track
      end

      def choose(by_class)
        tokens = by_class["PlaceToken"]
        pass = by_class["Pass"]&.first
        entity = tokens.first.entity
        return tokens.sample(random: @rng) unless pass && entity.corporation? # forced or not ours to judge
        return pass if price(entity) > entity.cash - @track.reserve(entity)

        Pick.weighted(tokens.map { |a| [score(a.city), a] }, @rng)
      end

      private

      def price(entity)
        step = @game.round.active_step
        tokens = step.respond_to?(:available_tokens) ? step.available_tokens(entity) : entity.tokens.reject(&:used)
        tokens.map(&:price).min || 0
      end

      def score(city)
        revenue = city.max_revenue
        free = city.tokens.count(&:nil?)
        revenue - (free * 5)
      end
    end
  end
end
