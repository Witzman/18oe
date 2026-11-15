# frozen_string_literal: true

module Oe
  class Bot
    # Station tokens (#293): place one whenever it is affordable. The offered
    # cities are already the legal ones (connected to the company's network,
    # inside its track rights; LegalActions#token_targets). A company without
    # a train keeps the cheapest depot train's price back, like Bot::Track.
    #
    # Choice (#322): the last free slot of a city and small cities (bottlenecks)
    # first, target cities (metropolis, port) higher, then revenue; seeded among
    # the best three. All weights are assumptions (rule 10), tuned after playtests. Before #293 the fallback passed while the company had no train or
    # less than 140 cash, so bots never placed a token in OR 1.1.
    class Token
      LAST_SLOT = 25      # placing here fills the city: nobody can follow
      BOTTLENECK = 10     # small city (at most SMALL_CITY slots): slots are scarce
      FREE_SLOT = 5       # penalty per slot still free after this token
      METROPOLIS = 20     # target city: metropolis
      PORT = 12           # target city: port hex
      SMALL_CITY = 2

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
        free = city.tokens.count(&:nil?)
        value = city.max_revenue - ((free - 1) * FREE_SLOT)
        value += LAST_SLOT if free == 1
        value += BOTTLENECK if city.tokens.size <= SMALL_CITY
        value += METROPOLIS if @game.metropolis_hex?(city.hex)
        value += PORT if port?(city.hex)
        value
      end

      def port?(hex)
        ports = @game.class::PORTS[hex.id]
        ports&.values&.any? { |exit| exit.is_a?(Hash) && exit[:port] } || false
      end
    end
  end
end
