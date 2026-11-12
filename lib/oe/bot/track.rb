# frozen_string_literal: true

module Oe
  class Bot
    # Track laying. Without a route evaluation yet (a later iteration): a
    # cheap proxy that prefers tiles which carry more stops, higher-colour
    # upgrades, hexes next to the company's own tokens, and low cost.
    # Spending the treasury on track before the first train exists is avoided
    # (same rule as Oe::StrategyPlayer).
    class Track
      COLOR_RANK = { white: 0, yellow: 1, green: 2, brown: 3, gray: 4 }.freeze
      MIN_CASH = 200

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def choose(by_class)
        tiles = by_class["LayTile"]
        pass = by_class["Pass"]&.first
        entity = tiles.first.entity
        return tiles.sample(random: @rng) unless pass # forced
        return pass if entity.trains.empty? && entity.cash < MIN_CASH

        Pick.weighted(tiles.map { |a| [score(entity, a), a] }, @rng)
      end

      private

      def score(entity, action)
        tile = action.tile
        stops = tile.cities.size * 2 + tile.towns.size
        color = COLOR_RANK.fetch(tile.color, 0)
        cost = @game.upgrade_cost(action.hex.tile, action.hex, entity, entity)
        near = own_token_near?(entity, action.hex) ? 6 : 0
        stops * 2 + color * 2 + near - (cost / 20.0)
      end

      def own_token_near?(entity, hex)
        return true if hex.tile.cities.any? { |city| city.tokened_by?(entity) }

        hex.neighbors.values.any? { |n| n.tile.cities.any? { |city| city.tokened_by?(entity) } }
      end
    end
  end
end
